#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/start-gsd-supervisor-daemon.sh -t TARGET [-r PROJECT_ROOT] [-s DAEMON_SESSION] [-n WATCHER_SESSION] [-m MODE] [-i WATCHER_INTERVAL] [-c CHECK_INTERVAL] [-q QUEUE_FILE] [-a]

Options:
  -t TARGET            worker tmux target to supervise (required)
  -r PROJECT_ROOT      target project directory (default: current directory)
  -s DAEMON_SESSION    tmux session for daemon process (default: gsd-supervisor-daemon)
  -n WATCHER_SESSION   tmux session for watcher process (default: gsd-supervisor)
  -m MODE              watcher mode: hook|ai|supervisor (default: supervisor)
  -i WATCHER_INTERVAL  watcher poll interval in seconds (default: 2)
  -c CHECK_INTERVAL    daemon health-check interval in seconds (default: 5)
  -q QUEUE_FILE        queue file path (default: .planning/supervisor/queue.txt)
  -a                   attach to daemon session after start
  -h                   show help
EOF
}

target=""
project_root="$PWD"
daemon_session="gsd-supervisor-daemon"
watcher_session="gsd-supervisor"
mode="supervisor"
watcher_interval="2"
check_interval="5"
queue_file=""
attach_now="false"

while getopts ":t:r:s:n:m:i:c:q:ah" opt; do
  case "$opt" in
    t) target="$OPTARG" ;;
    r) project_root="$OPTARG" ;;
    s) daemon_session="$OPTARG" ;;
    n) watcher_session="$OPTARG" ;;
    m) mode="$OPTARG" ;;
    i) watcher_interval="$OPTARG" ;;
    c) check_interval="$OPTARG" ;;
    q) queue_file="$OPTARG" ;;
    a) attach_now="true" ;;
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

if [[ -z "$queue_file" ]]; then
  queue_file="$project_root/.planning/supervisor/queue.txt"
fi

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is not installed." >&2
  exit 1
fi

daemon_cmd=(
  scripts/gsd-supervisor-daemon.sh
  -t "$target"
  -r "$project_root"
  -n "$watcher_session"
  -m "$mode"
  -i "$watcher_interval"
  -c "$check_interval"
  -q "$queue_file"
)
daemon_cmd_escaped="$(printf '%q ' "${daemon_cmd[@]}")"

if tmux has-session -t "$daemon_session" 2>/dev/null; then
  tmux kill-session -t "$daemon_session"
fi

tmux new-session \
  -d \
  -s "$daemon_session" \
  -n daemon \
  -c "$tool_root" \
  "bash -lc 'cd \"$tool_root\" && $daemon_cmd_escaped'"

tmux set-option -t "$daemon_session" remain-on-exit on >/dev/null

echo "Daemon started in tmux session '$daemon_session'."
echo "Worker target: $target"
echo "Watcher session: $watcher_session (mode: $mode)"
echo "Daemon check interval: ${check_interval}s | watcher poll: ${watcher_interval}s"
echo "Attach daemon log: tmux attach -t $daemon_session"
echo "Attach worker: tmux attach -t ${target%%:*}"
echo "Attach watcher: tmux attach -t $watcher_session"
echo "Stop daemon: tmux kill-session -t $daemon_session"

if [[ "$attach_now" == "true" ]]; then
  exec tmux attach -t "$daemon_session"
fi
