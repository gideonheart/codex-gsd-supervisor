#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/start-gsd-autoresponder.sh -t TARGET [-r PROJECT_ROOT] [-n SESSION_NAME] [-m MODE] [-i SECONDS] [-q QUEUE_FILE] [-e PHASE]

Options:
  -t TARGET        tmux target to watch (session, session:window, or %pane_id)
  -r PROJECT_ROOT  target project directory (default: current directory)
  -n SESSION_NAME  watcher tmux session name (default: gsd-autoresponder)
  -m MODE          decision mode: hook|ai|supervisor (default: supervisor)
  -i SECONDS       polling interval for watcher (default: 2)
  -q QUEUE_FILE    queue file path (default: .planning/supervisor/queue.txt)
  -e PHASE         bootstrap queue with: /clear then $gsd-execute-phase <PHASE>
  -v               enable auto-verification enqueue after $gsd-execute-phase
  -k VERIFY_CMD     verification command to enqueue (default: $gsd-verify-work)
  -h               show help
EOF
}

target=""
project_root="$PWD"
watcher_session="gsd-autoresponder"
mode="supervisor"
interval="2"
queue_file=""
execute_phase=""
auto_verify="false"
verify_command=""

while getopts ":t:r:n:m:i:q:e:vk:h" opt; do
  case "$opt" in
    t) target="$OPTARG" ;;
    r) project_root="$OPTARG" ;;
    n) watcher_session="$OPTARG" ;;
    m) mode="$OPTARG" ;;
    i) interval="$OPTARG" ;;
    q) queue_file="$OPTARG" ;;
    e) execute_phase="$OPTARG" ;;
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

if [[ "$mode" != "hook" && "$mode" != "ai" && "$mode" != "supervisor" ]]; then
  echo "Invalid -m '$mode'. Use 'hook', 'ai', or 'supervisor'." >&2
  exit 2
fi

if [[ -n "$execute_phase" ]]; then
  "$tool_root/scripts/supervisor-queue.sh" -r "$project_root" --file "$queue_file" set "/clear" "\$gsd-execute-phase $execute_phase" >/dev/null
fi

if tmux has-session -t "=$watcher_session" 2>/dev/null; then
  tmux kill-session -t "=$watcher_session"
fi

watcher_cmd=(
  scripts/tmux-gsd-autoresponder.sh
  -t "$target"
  -r "$project_root"
  -i "$interval"
  --mode "$mode"
  --queue-file "$queue_file"
)
if [[ "$auto_verify" == "true" ]]; then
  watcher_cmd+=(--auto-verify)
  if [[ -z "$verify_command" ]]; then
    verify_command='$gsd-verify-work'
  fi
  watcher_cmd+=(--verify-command "$verify_command")
fi
watcher_cmd_escaped="$(printf '%q ' "${watcher_cmd[@]}")"

tmux new-session \
  -d \
  -s "$watcher_session" \
  -n watch \
  -c "$tool_root" \
  "bash -lc 'cd \"$tool_root\" && $watcher_cmd_escaped'"

tmux set-option -t "$watcher_session" remain-on-exit on >/dev/null

echo "Watcher started in tmux session '$watcher_session' for target '$target' (mode: $mode, interval: ${interval}s)."
echo "Queue file: $queue_file"
echo "View logs with: tmux attach -t $watcher_session"
echo "Stop watcher with: tmux kill-session -t $watcher_session"
