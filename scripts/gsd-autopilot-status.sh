#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/gsd-autopilot-status.sh [-r PROJECT_ROOT] [--developer SESSION] [--driver SESSION]

Shows tmux + queue/log status for a target project under .planning/supervisor.
EOF
}

project_root="$PWD"
developer_session=""
driver_session=""

safe_basename() {
  local value="$1"
  value="${value##*/}"
  value="${value%%.*}"
  value="${value//[^a-zA-Z0-9._-]/-}"
  printf '%s' "$value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--project-root)
      project_root="${2:-}"
      shift 2
      ;;
    --developer)
      developer_session="${2:-}"
      shift 2
      ;;
    --driver)
      driver_session="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
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

base="$(safe_basename "$project_root")"
if [[ -z "$developer_session" ]]; then
  developer_session="codex-${base}-developer"
fi
if [[ -z "$driver_session" ]]; then
  driver_session="codex-${base}-driver"
fi

state_dir="$project_root/.planning/supervisor"
queue_file="$state_dir/queue.txt"

echo "Project: $project_root"
echo "Sessions:"
for s in \
  "$developer_session" \
  "$driver_session" \
  "gsd-${base}-supervisor-daemon" \
  "gsd-${base}-supervisor" \
  "gsd-${base}-meta-daemon" \
  "gsd-${base}-meta-supervisor" \
  "gsd-${base}-autoresponder" \
  gsd-supervisor-daemon \
  gsd-supervisor \
  gsd-meta-supervisor-daemon \
  gsd-meta-supervisor; do
  if tmux has-session -t "=$s" 2>/dev/null; then
    echo "  ok: $s"
  else
    echo "  --: $s"
  fi
done

echo "---"
if [[ -f "$state_dir/disabled" ]]; then
  echo "Automation disabled flag: present ($state_dir/disabled)"
else
  echo "Automation disabled flag: absent"
fi

echo "---"
echo "Queue: $queue_file"
if [[ -f "$queue_file" ]]; then
  nl -ba "$queue_file" | tail -n 40 || true
else
  echo "(missing)"
fi

echo "---"
for f in "$state_dir/autoresponder.log" "$state_dir/daemon.log" "$state_dir/meta-supervisor.log" "$state_dir/meta-daemon.log"; do
  echo "Log: $f"
  tail -n 18 "$f" 2>/dev/null || echo "(missing/empty)"
done
