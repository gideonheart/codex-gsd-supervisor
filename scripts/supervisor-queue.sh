#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/supervisor-queue.sh [-r PROJECT_ROOT] [--file PATH] <command> [args...]

Commands:
  set <cmd...>     replace queue with one command per argument
  append <cmd...>  append one command per argument
  show             print queued commands
  clear            empty queue
EOF
}

project_root="$PWD"
queue_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--project-root)
      project_root="${2:-}"
      shift 2
      ;;
    --file)
      queue_file="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

project_root="$(cd "$project_root" 2>/dev/null && pwd || true)"
if [[ -z "$project_root" ]]; then
  echo "Invalid project root." >&2
  exit 2
fi
if [[ -z "$queue_file" ]]; then
  queue_file="$project_root/.planning/supervisor/queue.txt"
fi

cmd="${1:-}"
if [[ -z "$cmd" ]]; then
  usage >&2
  exit 2
fi
shift || true

mkdir -p "$(dirname "$queue_file")"

case "$cmd" in
  set)
    : > "$queue_file"
    for item in "$@"; do
      printf '%s\n' "$item" >> "$queue_file"
    done
    ;;
  append)
    for item in "$@"; do
      printf '%s\n' "$item" >> "$queue_file"
    done
    ;;
  show)
    if [[ ! -f "$queue_file" ]]; then
      echo "(empty)"
      exit 0
    fi
    nl -ba "$queue_file"
    ;;
  clear)
    : > "$queue_file"
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac

echo "Queue file: $queue_file"
