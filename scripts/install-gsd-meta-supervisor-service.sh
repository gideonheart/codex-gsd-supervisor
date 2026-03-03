#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/install-gsd-meta-supervisor-service.sh -t TARGET [-r PROJECT_ROOT] [-u UNIT] [-s SESSION] [-i SECONDS] [-c COOLDOWN] [-k CHECK_INTERVAL] [-q QUEUE_FILE] [--no-start]

Options:
  -t TARGET      worker tmux target to analyze (required)
  -r PROJECT_ROOT
                 target project directory (default: current directory)
  -u UNIT        systemd user unit name without suffix (default: gsd-meta-supervisor)
  -s SESSION     tmux session name for meta loop (default: gsd-meta-supervisor)
  -i SECONDS     poll interval (default: 20)
  -c COOLDOWN    minimum seconds between queued commands (default: 180)
  -k CHECK_INTERVAL
                 daemon health-check interval (default: 5)
  -q QUEUE_FILE  queue file path (default: .planning/supervisor/queue.txt)
  --no-start     install only, do not enable/start
  -h             show help
EOF
}

target=""
project_root="$PWD"
unit_name="gsd-meta-supervisor"
session="gsd-meta-supervisor"
interval="20"
cooldown_seconds="180"
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
    -s)
      session="${2:-}"
      shift 2
      ;;
    -i)
      interval="${2:-}"
      shift 2
      ;;
    -c)
      cooldown_seconds="${2:-}"
      shift 2
      ;;
    -q)
      queue_file="${2:-}"
      shift 2
      ;;
    -k)
      check_interval="${2:-}"
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
  scripts/gsd-meta-supervisor-daemon.sh
  -t "$target"
  -r "$project_root"
  -s "$session"
  -i "$interval"
  -c "$cooldown_seconds"
  -k "$check_interval"
  -q "$queue_file"
)
exec_cmd_escaped="$(printf '%q ' "${exec_cmd[@]}")"
tool_root_escaped="$(printf '%q' "$tool_root")"

cat > "$unit_path" <<EOF
[Unit]
Description=GSD meta-supervisor watchdog
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
