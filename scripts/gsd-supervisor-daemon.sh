#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/gsd-supervisor-daemon.sh -t TARGET [-r PROJECT_ROOT] [-n WATCHER_SESSION] [-m MODE] [-i WATCHER_INTERVAL] [-c CHECK_INTERVAL] [-q QUEUE_FILE] [-v] [-k VERIFY_CMD]

Options:
  -t TARGET            worker tmux target (session, session:window, or %pane_id)
  -r PROJECT_ROOT      target project directory (default: current directory)
  -n WATCHER_SESSION   supervisor watcher tmux session name (default: gsd-supervisor)
  -m MODE              watcher mode: hook|ai|supervisor (default: supervisor)
  -i WATCHER_INTERVAL  watcher poll interval in seconds (default: 2)
  -c CHECK_INTERVAL    daemon health-check interval in seconds (default: 5)
  -q QUEUE_FILE        queue file path (default: .planning/supervisor/queue.txt)
  -v                   enable auto-verification enqueue after $gsd-execute-phase
  -k VERIFY_CMD         verification command to enqueue (default: $gsd-verify-work)
  -h                   show help
EOF
}

target=""
project_root="$PWD"
watcher_session="gsd-supervisor"
mode="supervisor"
watcher_interval="2"
check_interval="5"
queue_file=""
auto_verify="false"
verify_command=""

while getopts ":t:r:n:m:i:c:q:vk:h" opt; do
  case "$opt" in
    t) target="$OPTARG" ;;
    r) project_root="$OPTARG" ;;
    n) watcher_session="$OPTARG" ;;
    m) mode="$OPTARG" ;;
    i) watcher_interval="$OPTARG" ;;
    c) check_interval="$OPTARG" ;;
    q) queue_file="$OPTARG" ;;
    v) auto_verify="true" ;;
    k) verify_command="$OPTARG" ;;
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

if [[ "$mode" != "hook" && "$mode" != "ai" && "$mode" != "supervisor" ]]; then
  echo "Invalid -m '$mode'. Use 'hook', 'ai', or 'supervisor'." >&2
  exit 2
fi

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_root="$(cd "$project_root" 2>/dev/null && pwd || true)"
if [[ -z "$project_root" ]]; then
  echo "Invalid project root." >&2
  exit 2
fi
state_dir="$project_root/.planning/supervisor"
daemon_log="$state_dir/daemon.log"
disable_flag="$state_dir/disabled"
restart_cooldown_seconds="8"
last_restart_epoch="0"
last_health_state=""
last_missing_target_log_epoch="0"
missing_target_log_gap_seconds="20"

if [[ -z "$queue_file" ]]; then
  queue_file="$state_dir/queue.txt"
fi

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is not installed." >&2
  exit 1
fi

mkdir -p "$state_dir" "$(dirname "$queue_file")"

log_line() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$1" | tee -a "$daemon_log"
}

is_disabled_flag_set() {
  [[ -f "$disable_flag" ]] || return 1
  awk '
    {
      line=$0
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "" || substr(line, 1, 1) == "#") {
        next
      }
      lower=tolower(line)
      if (lower == "1" || lower == "true" || lower == "on" || lower == "pause") {
        found=1
      }
      exit
    }
    END { exit(found ? 0 : 1) }
  ' "$disable_flag"
}

worker_exists() {
  tmux display-message -p -t "$target" "#{pane_id}" >/dev/null 2>&1
}

watcher_health_reason() {
  local watcher_pane_id pane_dead pane_output

  if ! tmux has-session -t "=$watcher_session" 2>/dev/null; then
    echo "missing-session"
    return 1
  fi

  watcher_pane_id="$(tmux display-message -p -t "=$watcher_session" "#{pane_id}" 2>/dev/null || true)"
  if [[ -z "$watcher_pane_id" ]]; then
    echo "missing-pane"
    return 1
  fi

  pane_dead="$(tmux display-message -p -t "$watcher_pane_id" "#{pane_dead}" 2>/dev/null || echo "1")"
  if [[ "$pane_dead" == "1" ]]; then
    echo "pane-dead"
    return 1
  fi

  pane_output="$(tmux capture-pane -p -t "$watcher_pane_id" -S -40 2>/dev/null || true)"
  if printf '%s\n' "$pane_output" | grep -Eqi 'Target no longer exists|Unable to resolve tmux target|Invalid --mode|Unknown argument|tmux is not installed|codex CLI is not installed'; then
    echo "watcher-error-exit"
    return 1
  fi

  echo "healthy"
  return 0
}

restart_watcher() {
  local cmd
  cmd=(
    "$tool_root/scripts/start-gsd-autoresponder.sh"
    -t "$target"
    -r "$project_root"
    -n "$watcher_session"
    -m "$mode"
    -i "$watcher_interval"
    -q "$queue_file"
  )
  if [[ "$auto_verify" == "true" ]]; then
    cmd+=(-v)
    if [[ -n "$verify_command" ]]; then
      cmd+=(-k "$verify_command")
    fi
  fi
  (cd "$tool_root" && "${cmd[@]}")
}

shutdown() {
  log_line "daemon-stop target=$target watcher_session=$watcher_session"
  exit 0
}

trap shutdown INT TERM

log_line "daemon-start target=$target watcher_session=$watcher_session mode=$mode watcher_interval=${watcher_interval}s check_interval=${check_interval}s"

while true; do
  now_epoch="$(date +%s)"

  if is_disabled_flag_set; then
    if [[ "$last_health_state" != "disabled" ]]; then
      log_line "daemon-disabled flag=$disable_flag"
      last_health_state="disabled"
    fi
    sleep "$check_interval"
    continue
  fi

  if ! worker_exists; then
    if (( now_epoch - last_missing_target_log_epoch >= missing_target_log_gap_seconds )); then
      log_line "worker-missing target=$target waiting"
      last_missing_target_log_epoch="$now_epoch"
    fi
    sleep "$check_interval"
    continue
  fi

  health_reason="$(watcher_health_reason || true)"
  if [[ "$health_reason" == "healthy" ]]; then
    if [[ "$last_health_state" != "healthy" ]]; then
      log_line "watcher-healthy session=$watcher_session"
      last_health_state="healthy"
    fi
    sleep "$check_interval"
    continue
  fi

  if [[ "$last_health_state" != "$health_reason" ]]; then
    log_line "watcher-unhealthy session=$watcher_session reason=$health_reason"
    last_health_state="$health_reason"
  fi

  if (( now_epoch - last_restart_epoch < restart_cooldown_seconds )); then
    sleep "$check_interval"
    continue
  fi

  if restart_watcher; then
    last_restart_epoch="$now_epoch"
    log_line "watcher-restarted session=$watcher_session reason=$health_reason"
    last_health_state="healthy"
  else
    log_line "watcher-restart-failed session=$watcher_session reason=$health_reason"
  fi

  sleep "$check_interval"
done
