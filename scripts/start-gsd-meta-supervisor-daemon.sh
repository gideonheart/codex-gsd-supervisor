#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/start-gsd-meta-supervisor-daemon.sh -t TARGET [-r PROJECT_ROOT] [-d DAEMON_SESSION] [-s META_SESSION] [-i SECONDS] [-c COOLDOWN] [-q QUEUE_FILE] [-k CHECK_INTERVAL] [-a]

Options:
  -t TARGET         worker tmux target to analyze (required)
  -r PROJECT_ROOT   target project directory (default: current directory)
  -d DAEMON_SESSION tmux session for daemon wrapper (default: gsd-meta-supervisor-daemon)
  -s META_SESSION   tmux session name for meta loop (default: gsd-meta-supervisor)
  -i SECONDS        meta loop poll interval (default: 20)
  -c COOLDOWN       minimum seconds between queued commands (default: 180)
  -q QUEUE_FILE     queue file path (default: .planning/supervisor/queue.txt)
  -k SECONDS        daemon health-check interval (default: 5)
  -a                attach after start
  -h                show help
EOF
}

target=""
project_root="$PWD"
daemon_session="gsd-meta-supervisor-daemon"
meta_session="gsd-meta-supervisor"
interval="20"
cooldown_seconds="180"
queue_file=""
check_interval="5"
attach_now="false"

while getopts ":t:r:d:s:i:c:q:k:ah" opt; do
  case "$opt" in
    t) target="$OPTARG" ;;
    r) project_root="$OPTARG" ;;
    d) daemon_session="$OPTARG" ;;
    s) meta_session="$OPTARG" ;;
    i) interval="$OPTARG" ;;
    c) cooldown_seconds="$OPTARG" ;;
    q) queue_file="$OPTARG" ;;
    k) check_interval="$OPTARG" ;;
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
  scripts/gsd-meta-supervisor-daemon.sh
  -t "$target"
  -r "$project_root"
  -s "$meta_session"
  -i "$interval"
  -c "$cooldown_seconds"
  -q "$queue_file"
  -k "$check_interval"
)
daemon_cmd_escaped="$(printf '%q ' "${daemon_cmd[@]}")"

if tmux has-session -t "=$daemon_session" 2>/dev/null; then
  tmux kill-session -t "=$daemon_session"
fi

tmux new-session \
  -d \
  -s "$daemon_session" \
  -n daemon \
  -c "$tool_root" \
  "bash -lc 'cd \"$tool_root\" && $daemon_cmd_escaped'"

tmux set-option -t "$daemon_session" remain-on-exit on >/dev/null

echo "Meta-daemon started in tmux session '$daemon_session'."
echo "Worker target: $target"
echo "Meta loop session: $meta_session"
echo "Interval: ${interval}s | cooldown: ${cooldown_seconds}s | check: ${check_interval}s"
echo "Queue file: $queue_file"
echo "Attach: tmux attach -t $daemon_session"
echo "Stop: tmux kill-session -t $daemon_session"

if [[ "$attach_now" == "true" ]]; then
  exec tmux attach -t "$daemon_session"
fi
