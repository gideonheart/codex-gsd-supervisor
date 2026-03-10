#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/start-gsd-meta-supervisor.sh -t TARGET [-r PROJECT_ROOT] [-s SESSION] [-i SECONDS] [-c COOLDOWN] [-q QUEUE_FILE] [-a]

Options:
  -t TARGET      worker tmux target to analyze (required)
  -r PROJECT_ROOT
                 target project directory (default: current directory)
  -s SESSION     tmux session name (default: gsd-meta-supervisor)
  -i SECONDS     poll interval (default: 20)
  -c COOLDOWN    minimum seconds between queued commands (default: 180)
  -q QUEUE_FILE  queue file path (default: .planning/supervisor/queue.txt)
  -a             attach after start
  -h             show help
EOF
}

target=""
project_root="$PWD"
session="gsd-meta-supervisor"
interval="20"
cooldown_seconds="180"
queue_file=""
attach_now="false"

while getopts ":t:r:s:i:c:q:ah" opt; do
  case "$opt" in
    t) target="$OPTARG" ;;
    r) project_root="$OPTARG" ;;
    s) session="$OPTARG" ;;
    i) interval="$OPTARG" ;;
    c) cooldown_seconds="$OPTARG" ;;
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

loop_cmd=(
  scripts/gsd-meta-supervisor-loop.sh
  -t "$target"
  -r "$project_root"
  -i "$interval"
  -c "$cooldown_seconds"
  -q "$queue_file"
)
loop_cmd_escaped="$(printf '%q ' "${loop_cmd[@]}")"

if tmux has-session -t "=$session" 2>/dev/null; then
  tmux kill-session -t "=$session"
fi

tmux new-session \
  -d \
  -s "$session" \
  -n meta \
  -c "$tool_root" \
  "bash -lc 'cd \"$tool_root\" && $loop_cmd_escaped'"

tmux set-option -t "$session" remain-on-exit on >/dev/null

echo "Meta-supervisor started in tmux session '$session'."
echo "Worker target: $target"
echo "Interval: ${interval}s | cooldown: ${cooldown_seconds}s"
echo "Queue file: $queue_file"
echo "Attach: tmux attach -t $session"
echo "Stop: tmux kill-session -t $session"

if [[ "$attach_now" == "true" ]]; then
  exec tmux attach -t "$session"
fi
