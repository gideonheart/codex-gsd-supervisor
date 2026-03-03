#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/codex-tmux.sh [-r PROJECT_ROOT] [-s SESSION] [-w WINDOW] [-a]

Options:
  -r PROJECT_ROOT  target project directory for Codex session (default: current directory)
  -s SESSION  tmux session name (default: codex-agent)
  -w WINDOW   tmux window name for codex (default: codex)
  -a          attach immediately after ensuring session exists
EOF
}

project_root="$PWD"
session="codex-agent"
window="codex"
attach_now="false"

while getopts ":r:s:w:ah" opt; do
  case "$opt" in
    r) project_root="$OPTARG" ;;
    s) session="$OPTARG" ;;
    w) window="$OPTARG" ;;
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

project_root="$(cd "$project_root" 2>/dev/null && pwd || true)"
if [[ -z "$project_root" ]]; then
  echo "Invalid project root." >&2
  exit 2
fi

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is not installed." >&2
  exit 1
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "codex CLI is not installed." >&2
  exit 1
fi

if tmux has-session -t "$session" 2>/dev/null; then
  if tmux list-windows -t "$session" -F "#{window_name}" | grep -Fxq "$window"; then
    echo "Session '$session' already has window '$window'."
  else
    tmux new-window \
      -d \
      -t "$session" \
      -n "$window" \
      -c "$project_root" \
      "bash -lc 'cd \"$project_root\" && codex'"
    echo "Added codex window '$window' to existing session '$session'."
  fi
else
  tmux new-session \
    -d \
    -s "$session" \
    -n "$window" \
    -c "$project_root" \
    "bash -lc 'cd \"$project_root\" && codex'"
  echo "Started session '$session' with window '$window' in $project_root."
fi

tmux set-option -t "$session" remain-on-exit on >/dev/null

if tmux list-windows -t "$session" -F "#{window_name}" | grep -Fxq "$window"; then
  tmux select-window -t "${session}:${window}" >/dev/null
fi

echo "Attach with: tmux attach -t $session"
echo "Switch to codex window: tmux select-window -t ${session}:${window}"
echo "Detach with: Ctrl+b then d"

if [[ "$attach_now" == "true" ]]; then
  exec tmux attach -t "${session}:${window}"
fi
