#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/gsd-meta-supervisor-daemon.sh -t TARGET [-r PROJECT_ROOT] [-s SESSION] [-i SECONDS] [-c COOLDOWN] [-q QUEUE_FILE] [-k CHECK_INTERVAL]

Options:
  -t TARGET      worker tmux target to analyze (required)
  -r PROJECT_ROOT
                 target project directory (default: current directory)
  -s SESSION     meta-supervisor tmux session name (default: gsd-meta-supervisor)
  -i SECONDS     meta loop poll interval (default: 20)
  -c COOLDOWN    minimum seconds between queued commands (default: 180)
  -q QUEUE_FILE  queue file path (default: .planning/supervisor/queue.txt)
  -k SECONDS     daemon health-check interval (default: 5)
  -h             show help
EOF
}

target=""
project_root="$PWD"
session="gsd-meta-supervisor"
interval="20"
cooldown_seconds="180"
check_interval="5"
tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state_dir=""
queue_file=""
daemon_log=""
disable_flag=""
restart_cooldown_seconds="8"
last_restart_epoch="0"
last_health_state=""

while getopts ":t:r:s:i:c:q:k:h" opt; do
  case "$opt" in
    t) target="$OPTARG" ;;
    r) project_root="$OPTARG" ;;
    s) session="$OPTARG" ;;
    i) interval="$OPTARG" ;;
    c) cooldown_seconds="$OPTARG" ;;
    q) queue_file="$OPTARG" ;;
    k) check_interval="$OPTARG" ;;
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
daemon_log="$state_dir/meta-daemon.log"
disable_flag="$state_dir/disabled"

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

meta_health_reason() {
  local pane_id pane_dead pane_output

  if ! tmux has-session -t "=$session" 2>/dev/null; then
    echo "missing-session"
    return 1
  fi

  pane_id="$(tmux display-message -p -t "=$session" "#{pane_id}" 2>/dev/null || true)"
  if [[ -z "$pane_id" ]]; then
    echo "missing-pane"
    return 1
  fi

  pane_dead="$(tmux display-message -p -t "$pane_id" "#{pane_dead}" 2>/dev/null || echo "1")"
  if [[ "$pane_dead" == "1" ]]; then
    echo "pane-dead"
    return 1
  fi

  pane_output="$(tmux capture-pane -p -t "$pane_id" -S -40 2>/dev/null || true)"
  if printf '%s\n' "$pane_output" | grep -Eqi 'Missing required -t TARGET|Unknown option|tmux is not installed|codex CLI is not installed'; then
    echo "loop-error-exit"
    return 1
  fi

  echo "healthy"
  return 0
}

restart_meta_session() {
  local cmd
  cmd=(
    "$tool_root/scripts/start-gsd-meta-supervisor.sh"
    -t "$target"
    -r "$project_root"
    -s "$session"
    -i "$interval"
    -c "$cooldown_seconds"
    -q "$queue_file"
  )
  (cd "$tool_root" && "${cmd[@]}")
}

shutdown() {
  log_line "meta-daemon-stop target=$target session=$session"
  exit 0
}
trap shutdown INT TERM

log_line "meta-daemon-start target=$target session=$session interval=${interval}s cooldown=${cooldown_seconds}s check_interval=${check_interval}s"

while true; do
  now_epoch="$(date +%s)"

  if is_disabled_flag_set; then
    if [[ "$last_health_state" != "disabled" ]]; then
      log_line "meta-daemon-disabled flag=$disable_flag"
      last_health_state="disabled"
    fi
    sleep "$check_interval"
    continue
  fi

  if ! worker_exists; then
    if [[ "$last_health_state" != "worker-missing" ]]; then
      log_line "worker-missing target=$target waiting"
      last_health_state="worker-missing"
    fi
    sleep "$check_interval"
    continue
  fi

  health_reason="$(meta_health_reason || true)"
  if [[ "$health_reason" == "healthy" ]]; then
    if [[ "$last_health_state" != "healthy" ]]; then
      log_line "meta-session-healthy session=$session"
      last_health_state="healthy"
    fi
    sleep "$check_interval"
    continue
  fi

  if [[ "$last_health_state" != "$health_reason" ]]; then
    log_line "meta-session-unhealthy session=$session reason=$health_reason"
    last_health_state="$health_reason"
  fi

  if (( now_epoch - last_restart_epoch < restart_cooldown_seconds )); then
    sleep "$check_interval"
    continue
  fi

  if restart_meta_session; then
    last_restart_epoch="$now_epoch"
    log_line "meta-session-restarted session=$session reason=$health_reason"
    last_health_state="healthy"
  else
    log_line "meta-session-restart-failed session=$session reason=$health_reason"
  fi

  sleep "$check_interval"
done
