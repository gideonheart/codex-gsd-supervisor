#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/tmux-prime-codex-worker.sh -t TARGET

Options:
  -t TARGET  tmux target (session, session:window, or %pane_id)
  -h         show help
EOF
}

target=""

while getopts ":t:h" opt; do
  case "$opt" in
    t) target="$OPTARG" ;;
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

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is not installed." >&2
  exit 1
fi

pane_id="$(tmux display-message -p -t "$target" "#{pane_id}" 2>/dev/null || true)"
if [[ -z "$pane_id" ]]; then
  echo "Unable to resolve tmux target: $target" >&2
  exit 1
fi

# Keep this single-line so Enter submits it as a standalone message in Codex TUI.
prime_prompt='Use analytical supervisor mode for GSD: avoid blind defaults, evaluate tradeoffs vs goals/risk, run review loops before/after major changes, and continue autonomously until truly blocked.'

tmux send-keys -t "$pane_id" -l "$prime_prompt"
tmux send-keys -t "$pane_id" Enter

echo "Sent analytical supervisor prompt to $target ($pane_id)."
