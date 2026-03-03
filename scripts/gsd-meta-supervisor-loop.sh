#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/gsd-meta-supervisor-loop.sh -t TARGET [-r PROJECT_ROOT] [-i SECONDS] [-c COOLDOWN] [-q QUEUE_FILE]

Options:
  -t TARGET      worker tmux target (session, session:window, or %pane_id)
  -r PROJECT_ROOT
                 target project directory (default: current directory)
  -i SECONDS     poll interval (default: 20)
  -c COOLDOWN    minimum seconds between queued commands (default: 180)
  -q QUEUE_FILE  queue file path (default: .planning/supervisor/queue.txt)
  -h             show help
EOF
}

target=""
project_root="$PWD"
interval="20"
cooldown_seconds="180"
tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state_dir=""
queue_file=""
meta_log=""
meta_state_file=""

while getopts ":t:r:i:c:q:h" opt; do
  case "$opt" in
    t) target="$OPTARG" ;;
    r) project_root="$OPTARG" ;;
    i) interval="$OPTARG" ;;
    c) cooldown_seconds="$OPTARG" ;;
    q) queue_file="$OPTARG" ;;
    h)
      usage
      exit 0
      ;;
    \?)
      echo "Unknown option: -$OPTARG" >&2
      usage >&2
      exit 2
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$target" ]]; then
  echo "Missing required -t TARGET." >&2
  usage >&2
  exit 2
fi

project_root="$(cd "$project_root" 2>/dev/null && pwd || true)"
if [[ -z "$project_root" ]]; then
  echo "Invalid project root." >&2
  exit 2
fi
state_dir="$project_root/.planning/supervisor"
if [[ -z "$queue_file" ]]; then
  queue_file="$state_dir/queue.txt"
fi
meta_log="$state_dir/meta-supervisor.log"
meta_state_file="$state_dir/meta-supervisor.state"

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is not installed." >&2
  exit 1
fi
if ! command -v codex >/dev/null 2>&1; then
  echo "codex CLI is not installed." >&2
  exit 1
fi

mkdir -p "$state_dir" "$(dirname "$queue_file")"

last_action_epoch="0"
last_snapshot_signature=""
last_command=""

if [[ -f "$meta_state_file" ]]; then
  set +u
  # shellcheck disable=SC1090
  source "$meta_state_file" >/dev/null 2>&1 || true
  set -u
fi

log_line() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$1" | tee -a "$meta_log"
}

save_state() {
  {
    printf 'last_action_epoch=%q\n' "$last_action_epoch"
    printf 'last_snapshot_signature=%q\n' "$last_snapshot_signature"
    printf 'last_command=%q\n' "$last_command"
  } > "$meta_state_file"
}

queue_has_items() {
  if [[ ! -f "$queue_file" ]]; then
    return 1
  fi
  grep -Ev '^[[:space:]]*(#|$)' "$queue_file" >/dev/null 2>&1
}

queue_has_command() {
  local cmd="$1"
  [[ -f "$queue_file" ]] || return 1
  awk -v target="$cmd" '
    {
      line=$0
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == target) {
        found=1
        exit
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$queue_file"
}

canonicalize_gsd_command() {
  local raw="$1"
  printf '%s' "$raw" \
    | tr -d '\r' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | sed -E 's/^[0-9]+[.)][[:space:]]+//' \
    | sed -E 's/^`+//; s/`+$//'
}

command_allowed() {
  local cmd="$1"
  cmd="$(canonicalize_gsd_command "$cmd")"
  [[ -n "$cmd" ]] || return 1
  [[ "$cmd" =~ ^\$gsd-[a-z0-9-]+([[:space:]].*)?$ ]] || return 1
  if printf '%s' "$cmd" | grep -q '[[:cntrl:]]'; then
    return 1
  fi
  if printf '%s' "$cmd" | grep -q '`'; then
    return 1
  fi
  return 0
}

worker_exists() {
  tmux display-message -p -t "$target" "#{pane_id}" >/dev/null 2>&1
}

latest_verification_path() {
  ls -1 "$project_root"/.planning/phases/*/*-VERIFICATION.md 2>/dev/null | sort | tail -n 1
}

file_snippet() {
  local file="$1"
  local max_lines="$2"
  [[ -f "$file" ]] || return 0
  sed -n "1,${max_lines}p" "$file" 2>/dev/null || true
}

extract_explicit_next_command() {
  local text="$1"
  local cmd

  cmd="$(printf '%s\n' "$text" | awk '
    BEGIN { seen=0; budget=0 }
    /Next command:/ { seen=1; budget=10; next }
    seen {
      if (budget <= 0) { seen=0; next }
      if ($0 ~ /^[[:space:]]*$/) { budget--; next }
      if ($0 ~ /^[[:space:]]*[0-9]+[.)][[:space:]]+\$gsd-[a-zA-Z0-9-]+([[:space:]].*)?$/) {
        sub(/^[[:space:]]*[0-9]+[.)][[:space:]]+/, "", $0)
        print
        exit
      }
      if ($0 ~ /^[[:space:]]*\$gsd-[a-zA-Z0-9-]+([[:space:]].*)?$/) {
        sub(/^[[:space:]]+/, "", $0)
        print
        exit
      }
      budget--
    }
  ')"

  canonicalize_gsd_command "$cmd"
}

meta_raw_decision() {
  local pane_text="$1"
  local state_excerpt roadmap_excerpt verification_file verification_excerpt git_status_excerpt
  local out_file
  out_file="$(mktemp)"
  trap 'rm -f "$out_file"' RETURN

  state_excerpt="$(file_snippet "$project_root/.planning/STATE.md" 120)"
  roadmap_excerpt="$(file_snippet "$project_root/.planning/ROADMAP.md" 120)"
  verification_file="$(latest_verification_path || true)"
  verification_excerpt=""
  if [[ -n "${verification_file:-}" ]]; then
    verification_excerpt="$(file_snippet "$verification_file" 100)"
  fi
  git_status_excerpt="$(cd "$project_root" && git status --short | head -n 80)"

  if ! timeout 45s codex exec --color never -C "$project_root" -o "$out_file" - >/dev/null 2>&1 <<EOF; then
You are a fresh-context meta-supervisor for a GSD worker.
Your job is to decide whether to enqueue ONE high-leverage GSD command.

Output exactly three lines:
ACTION: WAIT|QUEUE
COMMAND: <single-line \$gsd-* command or empty>
REASON: <<=140 chars>

Rules:
- Prefer WAIT unless there is clear leverage.
- Never output prose in COMMAND; only one executable \$gsd-* command.
- If there is an explicit "Next command: \$gsd-..." in the worker output, that is usually highest priority.
- After major completion checkpoints, prefer a quality loop via:
  \$gsd-quick --full "<short task>"
  where the task requests: what went well, what was weak, what should be improved, and apply fixes with tests/checks.
- If worker signals defect/regression, prefer \$gsd-debug "<issue>".
- Avoid repeating the same command unless context changed materially.

Worker pane excerpt:
$pane_text

STATE.md excerpt:
$state_excerpt

ROADMAP.md excerpt:
$roadmap_excerpt

Latest verification file: ${verification_file:-"(none)"}
Verification excerpt:
$verification_excerpt

Git status excerpt:
$git_status_excerpt
EOF
    return 1
  fi

  cat "$out_file"
}

log_line "meta-supervisor-start target=$target interval=${interval}s cooldown=${cooldown_seconds}s queue_file=$queue_file"

while true; do
  now_epoch="$(date +%s)"

  if ! worker_exists; then
    log_line "worker-missing target=$target"
    sleep "$interval"
    continue
  fi

  pane_text="$(tmux capture-pane -p -t "$target" -S -260 2>/dev/null | tail -n 140)"
  snapshot_signature="$(printf '%s\n' "$pane_text" | sha1sum | awk '{print $1}')"

  if [[ "$snapshot_signature" == "$last_snapshot_signature" ]] && (( now_epoch - last_action_epoch < interval )); then
    sleep "$interval"
    continue
  fi

  explicit_cmd="$(extract_explicit_next_command "$pane_text")"
  if [[ -n "$explicit_cmd" ]]; then
    decision_action="QUEUE"
    decision_command="$explicit_cmd"
    decision_reason="Worker surfaced explicit next command."
  else
    raw="$(meta_raw_decision "$pane_text" || true)"
    decision_action="$(printf '%s\n' "$raw" | sed -nE 's/^ACTION:[[:space:]]*(WAIT|QUEUE).*$/\1/p' | head -n 1)"
    decision_command="$(printf '%s\n' "$raw" | sed -nE 's/^COMMAND:[[:space:]]*(.*)$/\1/p' | head -n 1)"
    decision_reason="$(printf '%s\n' "$raw" | sed -nE 's/^REASON:[[:space:]]*(.*)$/\1/p' | head -n 1)"
  fi

  decision_command="$(canonicalize_gsd_command "${decision_command:-}")"
  if [[ "${decision_action:-WAIT}" != "QUEUE" ]]; then
    last_snapshot_signature="$snapshot_signature"
    save_state
    log_line "meta-decision action=WAIT reason='${decision_reason//\'/\"}'"
    sleep "$interval"
    continue
  fi

  if ! command_allowed "$decision_command"; then
    last_snapshot_signature="$snapshot_signature"
    save_state
    log_line "meta-decision action=DROP_INVALID reason='${decision_reason//\'/\"}' cmd='${decision_command//\'/\"}'"
    sleep "$interval"
    continue
  fi

  if queue_has_command "$decision_command"; then
    last_snapshot_signature="$snapshot_signature"
    save_state
    log_line "meta-decision action=DROP_DUP_QUEUE reason='${decision_reason//\'/\"}' cmd='$decision_command'"
    sleep "$interval"
    continue
  fi

  if queue_has_items; then
    last_snapshot_signature="$snapshot_signature"
    save_state
    log_line "meta-decision action=DEFER_QUEUE_BUSY reason='${decision_reason//\'/\"}' cmd='$decision_command'"
    sleep "$interval"
    continue
  fi

  if [[ "$decision_command" == "$last_command" ]] && (( now_epoch - last_action_epoch < cooldown_seconds )); then
    last_snapshot_signature="$snapshot_signature"
    save_state
    log_line "meta-decision action=DROP_DUP_COOLDOWN reason='${decision_reason//\'/\"}' cmd='$decision_command'"
    sleep "$interval"
    continue
  fi

  if (( now_epoch - last_action_epoch < cooldown_seconds )); then
    last_snapshot_signature="$snapshot_signature"
    save_state
    log_line "meta-decision action=COOLDOWN_WAIT reason='${decision_reason//\'/\"}' cmd='$decision_command'"
    sleep "$interval"
    continue
  fi

  if "$tool_root/scripts/supervisor-queue.sh" -r "$project_root" --file "$queue_file" append "$decision_command" >/dev/null; then
    last_action_epoch="$now_epoch"
    last_command="$decision_command"
    last_snapshot_signature="$snapshot_signature"
    save_state
    log_line "meta-queue-append cmd='$decision_command' reason='${decision_reason//\'/\"}'"
  else
    last_snapshot_signature="$snapshot_signature"
    save_state
    log_line "meta-queue-append-failed cmd='$decision_command'"
  fi

  sleep "$interval"
done
