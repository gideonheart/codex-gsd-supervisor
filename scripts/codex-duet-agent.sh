#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/codex-duet-agent.sh --role <developer|driver> --project-root PATH

Roles:
  developer  Planning/orchestration role (receives TO=developer directives).
  driver     Execution role (receives TO=driver directives).

The process reads incoming lines from stdin, executes command content through `codex exec`,
and emits status updates back to the counterpart role as `TO=<counterpart>: ...`.
EOF
}

ROLE=""
COUNTERPART_SESSION=""
PROJECT_ROOT="$PWD"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--role)
      ROLE="${2:-}"
      shift 2
      ;;
    -p|--project-root|--project)
      PROJECT_ROOT="${2:-}"
      shift 2
      ;;
    -c|--counterpart-session)
      COUNTERPART_SESSION="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$ROLE" ]]; then
  echo "Missing --role." >&2
  usage
  exit 2
fi

if [[ "$ROLE" != "developer" && "$ROLE" != "driver" ]]; then
  echo "Invalid role '$ROLE'. Use developer or driver." >&2
  exit 2
fi

if [[ ! -d "$PROJECT_ROOT" ]]; then
  echo "Project root does not exist: $PROJECT_ROOT" >&2
  exit 2
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "codex CLI is not installed." >&2
  exit 1
fi
if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is not installed." >&2
  exit 1
fi

COUNTERPART_ROLE="developer"
if [[ "$ROLE" == "developer" ]]; then
  COUNTERPART_ROLE="driver"
fi

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

send_to_counterpart() {
  local line="$1"
  if [[ -z "$COUNTERPART_SESSION" ]]; then
    echo "No counterpart session configured; cannot forward: $line" >&2
    return 1
  fi
  tmux send-keys -t "$COUNTERPART_SESSION" -l "$line"
  tmux send-keys -t "$COUNTERPART_SESSION" Enter
}

run_codex() {
  local prompt="$1"
  local result
  local exit_code="0"
  local one_line

  printf '\n%s\n' "Running: $prompt"
  if ! result="$(cd "$PROJECT_ROOT" && codex exec "$prompt" 2>&1)"; then
    exit_code="$?"
    result="$(printf 'codex exec failed (exit=%s)\n%s' "$exit_code" "$result")"
  fi

  if [[ -z "$result" ]]; then
    result="(no output)"
  fi
  printf '%s\n' "$result"

  one_line="$(printf '%s' "$result" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
  if (( ${#one_line} > 900 )); then
    one_line="${one_line:0:900}..."
  fi

  local update_line="TO=${COUNTERPART_ROLE}: status/update, findings, next step."
  local evidence_line="TO=${COUNTERPART_ROLE}: command=$(printf '%q' "$prompt") | evidence=$(trim "$one_line")"

  printf '%s\n' "$update_line"
  printf '%s\n' "$evidence_line"
  send_to_counterpart "$update_line" >/dev/null
  send_to_counterpart "$evidence_line" >/dev/null
}

echo "Session boot placeholder."
echo "Role: $ROLE"
if [[ -n "$COUNTERPART_SESSION" ]]; then
  echo "Counterpart session: $COUNTERPART_SESSION"
fi
if [[ "$ROLE" == "developer" ]]; then
  echo "Mode: planning/orchestration side."
else
  echo "Mode: execution side."
fi
echo "Project root: $PROJECT_ROOT"
echo "Waiting for directed directives."

while IFS= read -r raw_line; do
  local_line="${raw_line//$'\r'/}"
  local_line="$(trim "$local_line")"
  [[ -z "$local_line" ]] && continue

  if [[ "$local_line" == TO=* ]]; then
    target="${local_line%%:*}"
    payload="${local_line#*:}"
    target_role="${target#TO=}"
    payload="$(trim "$payload")"

    if [[ "$target_role" == "$ROLE" ]]; then
      if [[ "$payload" == status/* ]] || [[ "$payload" == status/update* ]] || [[ "$payload" == findings* ]] || [[ "$payload" == "TO="* ]] || [[ "$payload" == command=* ]]; then
        echo "$payload"
        continue
      fi
      run_codex "$payload"
    elif [[ "$target_role" == "$COUNTERPART_ROLE" ]]; then
      if [[ "$payload" == status/* ]] || [[ "$payload" == status/update* ]] || [[ "$payload" == findings* ]] || [[ "$payload" == command=* ]]; then
        echo "$payload"
        continue
      fi
      send_to_counterpart "$local_line" >/dev/null || echo "counterpart session not reachable."
    fi
    continue
  fi

  run_codex "$local_line"
done
