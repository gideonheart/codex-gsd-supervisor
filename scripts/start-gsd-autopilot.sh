#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/start-gsd-autopilot.sh -r PROJECT_ROOT [-f] [--no-meta] [--mode MODE] [--developer SESSION] [--driver SESSION] [--seed CMD] [--no-seed] [--verify-cmd CMD] [--no-cleanup]

Starts a fully-autonomous local stack against a target project:
1) Developer+Driver Codex TUI pair (tmux sessions) + duet bridge
2) Main supervisor daemon watching the Driver pane (auto prompt handling + queue dispatch + supervisor mode)
3) Meta-supervisor daemon (optional) to inject high-leverage next $gsd-* commands

Options:
  -r PROJECT_ROOT        target project directory (required)
  -f, --fresh            recreate Developer/Driver tmux sessions
  --no-meta              do not start meta-supervisor daemon
  --mode MODE            watcher mode: hook|ai|supervisor (default: supervisor)
  --developer SESSION    override Developer tmux session name
  --driver SESSION       override Driver tmux session name
  --seed CMD             seed queue with CMD if empty (default: $gsd-progress)
  --no-seed              do not seed queue
  --verify-cmd CMD        verification command to enqueue after $gsd-execute-phase (default: $gsd-verify-work)
  --no-cleanup           do not kill legacy/global watcher tmux sessions
  -h, --help             show help

Example:
  scripts/start-gsd-autopilot.sh -r /path/to/karbit.kingom.lv --mode supervisor
EOF
}

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_root=""
fresh="false"
start_meta="true"
mode="supervisor"
developer_session=""
driver_session=""
seed_enabled="true"
seed_cmd='$gsd-progress'
verify_cmd='$gsd-verify-work'
cleanup_legacy="true"

safe_basename() {
  local value="$1"
  value="${value##*/}"
  value="${value%%.*}"
  value="${value//[^a-zA-Z0-9._-]/-}"
  printf '%s' "$value"
}

queue_is_empty() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  ! grep -Ev '^[[:space:]]*(#|$)' "$file" >/dev/null 2>&1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--project-root)
      project_root="${2:-}"
      shift 2
      ;;
    -f|--fresh)
      fresh="true"
      shift
      ;;
    --no-meta)
      start_meta="false"
      shift
      ;;
    --mode)
      mode="${2:-}"
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
    --seed)
      seed_cmd="${2:-}"
      shift 2
      ;;
    --no-seed)
      seed_enabled="false"
      shift
      ;;
    --verify-cmd)
      verify_cmd="${2:-}"
      shift 2
      ;;
    --no-cleanup)
      cleanup_legacy="false"
      shift
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

if [[ -z "$project_root" ]]; then
  echo "Missing -r PROJECT_ROOT." >&2
  usage >&2
  exit 2
fi

project_root="$(cd "$project_root" 2>/dev/null && pwd || true)"
if [[ -z "$project_root" ]]; then
  echo "Invalid project root." >&2
  exit 2
fi

if [[ "$mode" != "hook" && "$mode" != "ai" && "$mode" != "supervisor" ]]; then
  echo "Invalid --mode '$mode'. Use 'hook', 'ai', or 'supervisor'." >&2
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

base="$(safe_basename "$project_root")"
if [[ -z "$developer_session" ]]; then
  developer_session="codex-${base}-developer"
fi
if [[ -z "$driver_session" ]]; then
  driver_session="codex-${base}-driver"
fi

worker_target="${driver_session}:driver"
state_dir="$project_root/.planning/supervisor"
queue_file="$state_dir/queue.txt"

mkdir -p "$state_dir"
rm -f "$state_dir/disabled" 2>/dev/null || true

kill_session_if_exists() {
  local session="$1"
  if tmux has-session -t "=$session" 2>/dev/null; then
    tmux kill-session -t "=$session" 2>/dev/null || true
  fi
}

supervisor_daemon_session="gsd-${base}-supervisor-daemon"
supervisor_watcher_session="gsd-${base}-supervisor"
meta_daemon_session="gsd-${base}-meta-daemon"
meta_loop_session="gsd-${base}-meta-supervisor"

if [[ "$cleanup_legacy" == "true" ]]; then
  # Legacy project-scoped names from older runs.
  kill_session_if_exists "gsd-${base}-autoresponder"
  kill_session_if_exists "gsd-${base}-autoresponder-daemon"

  # Generic/global defaults (avoid two stacks fighting over the same queue/logs).
  kill_session_if_exists "gsd-supervisor"
  kill_session_if_exists "gsd-supervisor-daemon"
  kill_session_if_exists "gsd-meta-supervisor"
  kill_session_if_exists "gsd-meta-supervisor-daemon"
fi

duet_args=()
if [[ "$fresh" == "true" ]]; then
  duet_args+=(--fresh)
fi

"$tool_root/scripts/codex-duet-link.sh" -r "$project_root" "${duet_args[@]}" start "$developer_session" "$driver_session" >/dev/null

"$tool_root/scripts/tmux-prime-codex-worker.sh" -t "$worker_target" >/dev/null || true

"$tool_root/scripts/start-gsd-supervisor-daemon.sh" \
  -t "$worker_target" \
  -r "$project_root" \
  -s "$supervisor_daemon_session" \
  -n "$supervisor_watcher_session" \
  -m "$mode" \
  -v \
  -k "$verify_cmd" \
  >/dev/null

if [[ "$start_meta" == "true" ]]; then
  "$tool_root/scripts/start-gsd-meta-supervisor-daemon.sh" \
    -t "$worker_target" \
    -r "$project_root" \
    -d "$meta_daemon_session" \
    -s "$meta_loop_session" \
    >/dev/null
fi

if [[ "$seed_enabled" == "true" ]]; then
  mkdir -p "$(dirname "$queue_file")"
  touch "$queue_file"
  if queue_is_empty "$queue_file"; then
    "$tool_root/scripts/supervisor-queue.sh" -r "$project_root" --file "$queue_file" append "$seed_cmd" >/dev/null
  fi
fi

echo "Autopilot running for: $project_root"
echo "Developer session: $developer_session"
echo "Driver session: $driver_session (worker target: $worker_target)"
echo "Supervisor daemon: $supervisor_daemon_session (watcher: $supervisor_watcher_session, mode: $mode)"
if [[ "$start_meta" == "true" ]]; then
  echo "Meta daemon: $meta_daemon_session (loop: $meta_loop_session)"
else
  echo "Meta daemon: (disabled)"
fi
echo "Queue: $queue_file"
echo "Logs: $state_dir/{autoresponder.log,daemon.log,meta-supervisor.log,meta-daemon.log}"
echo "Attach: tmux attach -t $driver_session"
