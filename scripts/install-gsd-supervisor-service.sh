#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/install-gsd-supervisor-service.sh -t TARGET [-r PROJECT_ROOT] [-u UNIT_NAME] [-n WATCHER_SESSION] [-m MODE] [-i WATCHER_INTERVAL] [-c CHECK_INTERVAL] [-q QUEUE_FILE] [--no-start]

Options:
  -t TARGET            worker tmux target to supervise (required)
  -r PROJECT_ROOT      target project directory (default: current directory)
  -u UNIT_NAME         systemd user unit name without suffix (default: gsd-supervisor-watchdog)
  -n WATCHER_SESSION   tmux session for watcher process (default: gsd-supervisor)
  -m MODE              watcher mode: hook|ai|supervisor (default: supervisor)
  -i WATCHER_INTERVAL  watcher poll interval in seconds (default: 2)
  -c CHECK_INTERVAL    daemon health-check interval in seconds (default: 5)
  -q QUEUE_FILE        queue file path (default: .planning/supervisor/queue.txt)
  --no-start           install unit but do not enable/start it
  -h                   show help
EOF
}

target=""
project_root="$PWD"
unit_name="gsd-supervisor-watchdog"
watcher_session="gsd-supervisor"
mode="supervisor"
watcher_interval="2"
check_interval="5"
queue_file=""
start_unit="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t)
      target="${2:-}"
      shift 2
      ;;
    -r)
      project_root="${2:-}"
      shift 2
      ;;
    -u)
      unit_name="${2:-}"
      shift 2
      ;;
    -n)
      watcher_session="${2:-}"
      shift 2
      ;;
    -m)
      mode="${2:-}"
      shift 2
      ;;
    -i)
      watcher_interval="${2:-}"
      shift 2
      ;;
    -c)
      check_interval="${2:-}"
      shift 2
      ;;
    -q)
      queue_file="${2:-}"
      shift 2
      ;;
    --no-start)
      start_unit="false"
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

if [[ -z "$target" ]]; then
  echo "Missing required -t TARGET." >&2
  usage >&2
  exit 2
fi

if [[ "$mode" != "hook" && "$mode" != "ai" && "$mode" != "supervisor" ]]; then
  echo "Invalid -m '$mode'. Use 'hook', 'ai', or 'supervisor'." >&2
  exit 2
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "systemctl is not installed." >&2
  exit 1
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

unit_dir="$HOME/.config/systemd/user"
unit_path="$unit_dir/${unit_name}.service"
mkdir -p "$unit_dir"

exec_cmd=(
  scripts/gsd-supervisor-daemon.sh
  -t "$target"
  -r "$project_root"
  -n "$watcher_session"
  -m "$mode"
  -i "$watcher_interval"
  -c "$check_interval"
  -q "$queue_file"
)
exec_cmd_escaped="$(printf '%q ' "${exec_cmd[@]}")"
tool_root_escaped="$(printf '%q' "$tool_root")"

cat > "$unit_path" <<EOF
[Unit]
Description=GSD supervisor watchdog for Codex tmux worker
After=default.target

[Service]
Type=simple
WorkingDirectory=$tool_root
ExecStart=/usr/bin/env bash -lc 'cd $tool_root_escaped && $exec_cmd_escaped'
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

echo "Wrote unit: $unit_path"

systemctl --user daemon-reload

if [[ "$start_unit" == "true" ]]; then
  systemctl --user enable --now "${unit_name}.service"
  echo "Enabled and started: ${unit_name}.service"
else
  echo "Installed only (not started): ${unit_name}.service"
fi

echo "Status: systemctl --user status ${unit_name}.service"
echo "Logs: journalctl --user -u ${unit_name}.service -f"
