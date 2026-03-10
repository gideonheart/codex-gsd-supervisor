#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/codex-duet-link.sh <command> [options] [args]

Commands:
  start [developer-session] [driver-session]   Start and prime linked Codex sessions.
  stop                                        Stop bridge if running.
  send <developer|driver> <message...>         Send message to target session.
  status                                      Show pair state and bridge status.

Options:
  -r, --project-root PATH   target project directory (default: current directory)
  -u, --ui                  start real Codex TUI sessions for both roles (default)
  -a, --agent               start command-executor shell sessions (codex-duet-agent)
  -f, --fresh               recreate sessions from scratch (default: reuse existing)
  -n, --pair-name NAME      explicit logical pair namespace (default from session names)
  -s, --state-dir PATH      custom state directory (overrides all auto pathing)
  -h, --help                show help

Examples:
  scripts/codex-duet-link.sh -r /path/to/project start
  scripts/codex-duet-link.sh -r /path/to/project start codex-myproj-developer codex-myproj-driver
  scripts/codex-duet-link.sh -r /path/to/project start --fresh
  scripts/codex-duet-link.sh -r /path/to/project start --agent
  scripts/codex-duet-link.sh -r /path/to/project send developer '$gsd-resume-work'
  scripts/codex-duet-link.sh -r /path/to/project status
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$PWD"
PAIR_MODE="ui"
START_FRESH="false"
PAIR_NAME=""
STATE_DIR_OVERRIDE=""
CURRENT_STATE_DIR=""

safe_basename() {
  local value="$1"
  value="${value##*/}"
  value="${value%%.*}"
  value="${value//[^a-zA-Z0-9._-]/-}"
  printf '%s' "$value"
}

normalize_root() {
  local root="$1"
  root="$(cd "$root" 2>/dev/null && pwd || true)"
  if [[ -z "$root" ]]; then
    echo "Invalid project root: $1" >&2
    exit 2
  fi
  printf '%s\n' "$root"
}

PROJECT_ROOT="$(normalize_root "$PROJECT_ROOT")"

state_dir() {
  if [[ -z "$CURRENT_STATE_DIR" ]]; then
    set_state_context
  fi
  printf '%s' "$CURRENT_STATE_DIR"
}

pair_state_file() {
  printf '%s/pair-state.sh\n' "$(state_dir)"
}

bridge_pid_file() {
  printf '%s/duet-bridge.pid\n' "$(state_dir)"
}

bridge_log_file() {
  printf '%s/duet-bridge.log\n' "$(state_dir)"
}

state_root() {
  printf '%s/.planning/supervisor/pair-link' "$PROJECT_ROOT"
}

safe_state_name() {
  local value="$1"
  value="${value//[^a-zA-Z0-9._-]/-}"
  printf '%s' "$value"
}

set_state_context() {
  local developer_session="${1:-}"
  local driver_session="${2:-}"
  local root

  if [[ -n "$STATE_DIR_OVERRIDE" ]]; then
    CURRENT_STATE_DIR="$STATE_DIR_OVERRIDE"
    return
  fi

  if [[ -n "$PAIR_NAME" ]]; then
    CURRENT_STATE_DIR="$(state_root)/$(safe_state_name "$PAIR_NAME")"
    return
  fi

  local resolved_developer="$developer_session"
  local resolved_driver="$driver_session"
  if [[ -z "$resolved_developer" || -z "$resolved_driver" ]]; then
    local base
    base="$(safe_basename "$PROJECT_ROOT")"
    local -a sessions
    mapfile -t sessions < <(default_sessions "$base")
    resolved_developer="${sessions[0]:-}"
    resolved_driver="${sessions[1]:-}"
  fi

  CURRENT_STATE_DIR="$(state_root)/$(safe_state_name "${resolved_developer}-${resolved_driver}")"
}

default_sessions() {
  local base="$1"
  printf 'codex-%s-developer\n' "$base"
  printf 'codex-%s-driver\n' "$base"
}

load_pair_state() {
  if [[ -f "$(pair_state_file)" ]]; then
    # shellcheck source=/dev/null
    source "$(pair_state_file)"
  fi
}

resolve_session() {
  local role="$1"
  load_pair_state
  case "$role" in
    developer)
      echo "${DEVELOPER_SESSION:-}"
      ;;
    driver)
      echo "${DRIVER_SESSION:-}"
      ;;
    *)
      echo ""
      ;;
  esac
}

write_pair_state() {
  local developer_session="$1"
  local driver_session="$2"
  local pair_mode="$3"
  mkdir -p "$(state_dir)"
  cat > "$(pair_state_file)" <<EOF
DEVELOPER_SESSION=$developer_session
DRIVER_SESSION=$driver_session
PROJECT_ROOT=$PROJECT_ROOT
PAIR_MODE=$pair_mode
EOF
}

ensure_agent_session() {
  local session_name="$1"
  local window_name="$2"
  local recreate="$3"
  local role="$4"
  local counterpart="$5"

  if [[ "$recreate" == "true" ]] && tmux has-session -t "$session_name" 2>/dev/null; then
    tmux kill-session -t "$session_name"
  fi

  if ! tmux has-session -t "$session_name" 2>/dev/null; then
    tmux new-session -d -s "$session_name" -n "$window_name" "$SCRIPT_DIR/codex-duet-agent.sh --role \"$role\" --project-root \"$PROJECT_ROOT\" --counterpart-session \"$counterpart\""
  fi
}

ensure_codex_ui_session() {
  local session_name="$1"
  local window_name="$2"
  local recreate="$3"

  if [[ "$recreate" == "true" ]] && tmux has-session -t "$session_name" 2>/dev/null; then
    tmux kill-session -t "$session_name"
  fi

  if ! tmux has-session -t "$session_name" 2>/dev/null; then
    tmux new-session -d -s "$session_name" -n "$window_name" -x 300 -y 80 -c "$PROJECT_ROOT" "codex"
  elif ! tmux list-windows -t "$session_name" -F "#{window_name}" | rg -q "^${window_name}$"; then
    tmux new-window -d -t "$session_name" -n "$window_name" -x 300 -y 80 -c "$PROJECT_ROOT" "codex"
  fi

  tmux set-option -t "$session_name" remain-on-exit on >/dev/null
}

prime_ui_session() {
  local session_name="$1"
  local role="$2"
  local window_name="$3"

  local message
  if [[ "$role" == "developer" ]]; then
    message='Use analytical GSD coordination mode. You are the Developer Codex for this pair. Triage worker prompts quickly: for numbered menus, type only the number and Enter; for yes/no prompts, send y or n and Enter; for permission prompts, type the safest valid answer and continue.'
  else
    message='Use analytical GSD execution mode. You are the Driver Codex for this pair. Triage worker prompts quickly: for numbered menus, type only the number and Enter; for yes/no prompts, send y or n and Enter; for /model or /agent prompts, follow exact command syntax.'
  fi
  if tmux has-session -t "${session_name}:${window_name}" 2>/dev/null; then
    tmux send-keys -t "${session_name}:${window_name}" -l "$message"
    tmux send-keys -t "${session_name}:${window_name}" Enter
  else
    printf '[%s] unable-to-prime session=%s:%s (target missing)\n' \
      "$(date '+%F %T')" "$session_name" "$window_name" >> "$(bridge_log_file)"
  fi
}

cleanup_legacy_sessions() {
  local base="$1"
  local candidate

  for candidate in \
    "codex-${base}-controller" \
    "codex-${base}-worker"; do
    if tmux has-session -t "$candidate" 2>/dev/null; then
      tmux kill-session -t "$candidate"
      printf '[%s] cleaned legacy session=%s\n' "$(date '+%F %T')" "$candidate" >> "$(bridge_log_file)"
    fi
  done

  for candidate in \
    "codex-karbit-controller" \
    "codex-karbit-worker" \
    "codex-lab-developer" \
    "codex-lab-driver" \
    "duo-test-developer" \
    "duo-test-driver"; do
    if tmux has-session -t "$candidate" 2>/dev/null; then
      tmux kill-session -t "$candidate"
      printf '[%s] cleaned legacy session=%s\n' "$(date '+%F %T')" "$candidate" >> "$(bridge_log_file)"
    fi
  done
}

sanitize_message() {
  local value="$1"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  value="$(printf '%s' "$value" | tr -s '[:space:]' ' ')"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

start_bridge() {
  local developer_session="$1"
  local driver_session="$2"
  local pid_file
  local existing_pid

  pid_file="$(bridge_pid_file)"
  mkdir -p "$(state_dir)"
  if [[ -f "$pid_file" ]]; then
    existing_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      return 0
    fi
    rm -f "$pid_file"
  fi

  printf '[%s] starting codex-duet-bridge pair=%s:%s state_dir=%s\n' "$(date '+%F %T')" "$developer_session" "$driver_session" "$(state_dir)" >> "$(bridge_log_file)"
  setsid nohup "$SCRIPT_DIR/codex-duet-bridge.sh" "$developer_session" "$driver_session" "$(state_dir)" \
    >> "$(bridge_log_file)" 2>&1 < /dev/null &
  echo "$!" > "$pid_file"
}

start_pair() {
  local developer_session="${1:-}"
  local driver_session="${2:-}"
  local recreate="$3"
  local pair_mode="$4"
  local base

  if [[ -n "$developer_session" ]] && [[ -z "$driver_session" ]] || \
    [[ -z "$developer_session" ]] && [[ -n "$driver_session" ]]; then
    echo "Provide both developer and driver session names, or omit both for defaults." >&2
    exit 2
  fi

  if [[ "$developer_session" == "$driver_session" && -n "$developer_session" ]]; then
    echo "Developer and driver session names must be different." >&2
    exit 2
  fi

  if [[ -z "$developer_session" || -z "$driver_session" ]]; then
    base="$(safe_basename "$PROJECT_ROOT")"
    local -a sessions
    mapfile -t sessions < <(default_sessions "$base")
    developer_session="${sessions[0]:-}"
    driver_session="${sessions[1]:-}"
  else
    base="$(safe_basename "$PROJECT_ROOT")"
  fi
  set_state_context "$developer_session" "$driver_session"

  if [[ "$recreate" == "true" ]]; then
    cleanup_legacy_sessions "$base"
  fi

  if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux is not installed." >&2
    exit 1
  fi
  if ! command -v codex >/dev/null 2>&1; then
    echo "codex CLI is not installed." >&2
    exit 1
  fi

  if [[ "$pair_mode" == "agent" ]]; then
    ensure_agent_session "$developer_session" "developer" "$recreate" "developer" "$driver_session"
    ensure_agent_session "$driver_session" "driver" "$recreate" "driver" "$developer_session"
  else
    ensure_codex_ui_session "$developer_session" "developer" "$recreate"
    ensure_codex_ui_session "$driver_session" "driver" "$recreate"
    prime_ui_session "$developer_session" "developer" "developer"
    prime_ui_session "$driver_session" "driver" "driver"
  fi

  start_bridge "$developer_session" "$driver_session"

  write_pair_state "$developer_session" "$driver_session" "$pair_mode"
  mkdir -p "$(state_dir)"
  # Keep bridge PID in all modes so status and management tooling can track it.

  printf 'Started duo sessions and connected roles.\n'
  printf 'Developer (planning/orchestration): %s\n' "$developer_session"
  printf 'Driver (execution): %s\n' "$driver_session"
  if [[ "$pair_mode" == "ui" ]]; then
    printf 'Mode: Codex UI pair with bridge forwarding.\n'
  else
    printf 'Mode: agent loop sessions (codex-duet-agent with bridge forwarding).\n'
  fi
  printf 'Attach: tmux attach -t %s\n' "$developer_session"
  printf 'Attach: tmux attach -t %s\n' "$driver_session"
}

stop_bridge() {
  set_state_context
  local pid_file="$(bridge_pid_file)"
  if [[ -f "$pid_file" ]]; then
    local pid=""
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      echo "Stopped bridge pid=$pid"
    else
      echo "No bridge process found for pid=$pid"
    fi
    rm -f "$pid_file"
  else
    echo "No bridge PID file."
  fi
}

send_to_peer() {
  local role="${1:-}"
  shift
  local message="$*"
  local target

  target="$(resolve_session "$role")"
  if [[ -z "$target" ]]; then
    echo "No configured target for role '$role'. Run start first." >&2
    exit 2
  fi

  message="$(sanitize_message "$message")"
  if [[ -z "$message" ]]; then
    echo "Message empty after sanitization." >&2
    exit 2
  fi

  tmux send-keys -t "$target" -l "$message"
  tmux send-keys -t "$target" Enter
  printf '[%s] direct-send role=%s target=%s message=%s\n' "$(date '+%F %T')" "$role" "$target" "$message" >> "$(bridge_log_file)"
}

status() {
  local show_all="${1:-false}"
  if [[ "$show_all" == "true" ]]; then
    echo "Configured pairs:"
    local pair_dir
    while IFS= read -r pair_dir; do
      [[ -z "$pair_dir" ]] && continue
      local pair_state="$pair_dir/pair-state.sh"
      local d_session="${developer_session:-unknown}"
      local r_session="${driver_session:-unknown}"
      local local_mode="${pair_mode:-unknown}"
      if [[ -f "$pair_state" ]]; then
        # shellcheck source=/dev/null
        source "$pair_state"
        d_session="${DEVELOPER_SESSION:-unknown}"
        r_session="${DRIVER_SESSION:-unknown}"
        local_mode="${PAIR_MODE:-unknown}"
      fi
      local pair_id
      pair_id="$(basename "$pair_dir")"
      printf '  %s: developer=%s driver=%s mode=%s\n' "$pair_id" "$d_session" "$r_session" "$local_mode"
    done < <(find "$(state_root)" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null)
    echo "---"
    tmux ls | rg -n "pair-link|duet-bridge|codex-lab|codex-probe|codex-karbit" || true
    return
  fi

  set_state_context
  local developer_session driver_session pair_mode pid_file pid log_file
  load_pair_state
  developer_session="${DEVELOPER_SESSION:-unknown}"
  driver_session="${DRIVER_SESSION:-unknown}"
  pair_mode="${PAIR_MODE:-ui}"
  pid_file="$(bridge_pid_file)"
  log_file="$(bridge_log_file)"
  if [[ -f "$pid_file" ]]; then
    pid="$(cat "$pid_file" 2>/dev/null || true)"
  else
    pid=""
  fi

  echo "Configured pair:"
  echo "  Project root: $PROJECT_ROOT"
  echo "  Mode: $pair_mode"
  echo "  Developer: $developer_session"
  echo "  Driver: $driver_session"
  if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "  Bridge running pid=$pid"
  elif [[ -n "${pid:-}" ]]; then
    echo "  Legacy bridge pid file exists but no process found (pid=$pid)."
    rm -f "$pid_file"
  else
    echo "  No bridge PID file."
  fi
  echo "---"
  tmux ls | rg -n "(^|:)$developer_session(:|\\s)|(^|:)$driver_session(:|\\s)|pair-link|duet-bridge|codex-lab|codex-probe|codex-karbit" || true
  echo "---"
  tail -n 20 "$log_file" 2>/dev/null || true
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--project-root)
        if [[ $# -lt 2 ]]; then
          echo "Missing value for --project-root." >&2
          exit 2
        fi
        PROJECT_ROOT="$(normalize_root "$2")"
        shift 2
        ;;
      --project-root=*)
        PROJECT_ROOT="$(normalize_root "${1#*=}")"
        shift
        ;;
      -u|--ui)
        PAIR_MODE="ui"
        shift
        ;;
      -a|--agent)
        PAIR_MODE="agent"
        shift
        ;;
      -f|--fresh)
        START_FRESH="true"
        shift
        ;;
      -n|--pair-name)
        if [[ $# -lt 2 ]]; then
          echo "Missing value for --pair-name." >&2
          exit 2
        fi
        PAIR_NAME="$2"
        shift 2
        ;;
      -s|--state-dir)
        if [[ $# -lt 2 ]]; then
          echo "Missing value for --state-dir." >&2
          exit 2
        fi
        STATE_DIR_OVERRIDE="$2"
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

  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    start)
      local start_fresh="$START_FRESH"
      local developer_session=""
      local driver_session=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          -a|--agent)
            PAIR_MODE="agent"
            shift
            ;;
          -u|--ui)
            PAIR_MODE="ui"
            shift
            ;;
          -f|--fresh)
            start_fresh="true"
            shift
            ;;
          --)
            shift
            break
            ;;
          -*)
            echo "Unknown option for start: $1" >&2
            usage
            exit 2
            ;;
          *)
            if [[ -z "$developer_session" ]]; then
              developer_session="$1"
            elif [[ -z "$driver_session" ]]; then
              driver_session="$1"
            else
              echo "Too many arguments for start: $1" >&2
              usage
              exit 2
            fi
            shift
            ;;
        esac
      done
      start_pair "$developer_session" "$driver_session" "$start_fresh" "$PAIR_MODE"
      ;;
    stop)
      stop_bridge
      ;;
    send)
      if [[ $# -lt 2 ]]; then
        echo "Missing role and message." >&2
        usage
        exit 2
      fi
      local role="$1"
      shift
      send_to_peer "$role" "$*"
      ;;
    status)
      if [[ "${1:-}" == "--all" ]]; then
        status true
      else
        status false
      fi
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
