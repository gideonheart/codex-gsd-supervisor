#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/tmux-gsd-autoresponder.sh -t TARGET [-r PROJECT_ROOT] [-i SECONDS] [--mode MODE] [--queue-file PATH] [--dry-run]

Options:
  -t TARGET          tmux target (session, session:window, or %pane_id)
  -r PROJECT_ROOT    target project directory (default: current directory)
  -i SECONDS         polling interval (default: 2)
  --mode MODE        decision mode: hook|ai|supervisor (default: hook)
  --queue-file PATH  command queue file (default: .planning/supervisor/queue.txt)
  --auto-verify      after a successful '$gsd-execute-phase N' dispatch, enqueue verification next
  --verify-command   verification command to enqueue (default: $gsd-verify-work)
  --dry-run          print actions without sending keys
  --self-test        run prompt-decision regression tests and exit
  -h                 show help
EOF
}

target=""
project_root="$PWD"
interval="2"
mode="hook"
dry_run="false"
self_test="false"
auto_verify="false"
verify_command='$gsd-verify-work'
state_dir=""
queue_file=""
log_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t)
      target="${2:-}"
      shift 2
      ;;
    -r|--project-root)
      project_root="${2:-}"
      shift 2
      ;;
    -i)
      interval="${2:-}"
      shift 2
      ;;
    --mode)
      mode="${2:-}"
      shift 2
      ;;
    --queue-file)
      queue_file="${2:-}"
      shift 2
      ;;
    --auto-verify)
      auto_verify="true"
      shift
      ;;
    --verify-command)
      verify_command="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run="true"
      shift
      ;;
    --self-test)
      self_test="true"
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

if [[ "$self_test" != "true" && -z "$target" ]]; then
  echo "Missing required -t TARGET." >&2
  usage >&2
  exit 2
fi

project_root="$(cd "$project_root" 2>/dev/null && pwd || true)"
if [[ -z "$project_root" ]]; then
  echo "Invalid project root." >&2
  exit 2
fi
state_dir="$project_root/.planning/supervisor"
if [[ -z "$queue_file" ]]; then
  queue_file="$state_dir/queue.txt"
fi
log_file="$state_dir/autoresponder.log"

if [[ "$mode" != "hook" && "$mode" != "ai" && "$mode" != "supervisor" ]]; then
  echo "Invalid --mode '$mode'. Use 'hook', 'ai', or 'supervisor'." >&2
  exit 2
fi

verify_command="$(printf '%s' "$verify_command" | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
if [[ "$auto_verify" == "true" ]]; then
  if [[ -z "$verify_command" ]]; then
    verify_command='$gsd-verify-work'
  fi
  if ! [[ "$verify_command" =~ ^\$gsd-[a-z0-9-]+([[:space:]].*)?$ ]]; then
    echo "Invalid --verify-command '$verify_command'. Must be a single-line \$gsd-* command." >&2
    exit 2
  fi
fi

if [[ "$self_test" != "true" ]] && ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is not installed." >&2
  exit 1
fi

if [[ "$self_test" != "true" ]] && [[ "$mode" == "ai" || "$mode" == "supervisor" ]] && ! command -v codex >/dev/null 2>&1; then
  echo "codex CLI is not installed (required for --mode ai/supervisor)." >&2
  exit 1
fi

pane_id=""
if [[ "$self_test" != "true" ]]; then
  pane_id="$(tmux display-message -p -t "$target" "#{pane_id}" 2>/dev/null || true)"
  if [[ -z "$pane_id" ]]; then
    echo "Unable to resolve tmux target: $target" >&2
    exit 1
  fi

  mkdir -p "$state_dir" "$(dirname "$queue_file")"

  echo "Watching $target ($pane_id) every ${interval}s (mode: $mode, dry-run: $dry_run)"
  echo "Queue: $queue_file"
  echo "Log: $log_file"
fi

last_hash=""
last_prompt_signature=""
last_action_epoch="0"
min_action_gap_seconds="4"
last_agent_route_epoch="0"
agent_route_gap_seconds="90"
last_agent_target=""
last_agent_target_epoch="0"
agent_route_repeat_gap_seconds="900"
pending_queue_command=""
pending_submit_attempts="0"
max_submit_attempts="6"
supervisor_action_gap_seconds="25"
last_supervisor_epoch="0"
last_supervisor_signature=""
last_supervisor_message=""
supervisor_max_message_chars="460"
supervisor_context_state_lines="140"
supervisor_context_roadmap_lines="130"
supervisor_context_verification_lines="140"
stale_composer_timeout_seconds="20"
stale_composer_retry_gap_seconds="20"
stale_composer_text=""
stale_composer_since_epoch="0"
last_stale_clear_epoch="0"
last_respawn_epoch="0"
respawn_retry_gap_seconds="12"
post_respawn_idle_seconds="18"
dead_pane_consecutive_checks_required="2"
dead_pane_consecutive_count="0"

log_line() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$1" | tee -a "$log_file"
}

send_text_and_enter() {
  local text="$1"
  local composer_text
  if [[ "$dry_run" == "true" ]]; then
    echo "[dry-run] send text+enter: $text"
    return
  fi
  tmux send-keys -t "$pane_id" -l "$text"
  sleep 0.05
  tmux send-keys -t "$pane_id" Enter

  # Fallback: if command is still visible in composer, send one more Enter.
  sleep 0.2
  composer_text="$(extract_composer_text "$(capture_tail_view)")"
  if [[ "$composer_text" == "$text" || "$composer_text" == "$text"* ]]; then
    tmux send-keys -t "$pane_id" Enter
  fi
}

send_action() {
  local action="$1"
  case "$action" in
    ENTER)
      if [[ "$dry_run" == "true" ]]; then
        echo "[dry-run] send: Enter"
      else
        tmux send-keys -t "$pane_id" Enter
      fi
      ;;
    YES)
      send_text_and_enter "y"
      ;;
    NO)
      send_text_and_enter "n"
      ;;
    NUM:*)
      send_text_and_enter "${action#NUM:}"
      ;;
    AGENT:*)
      send_text_and_enter "/agent ${action#AGENT:}"
      ;;
    *)
      ;;
  esac
}

is_busy() {
  local text="$1"
  local recent
  recent="$(printf '%s\n' "$text" | tail -n 12)"

  # Only treat the pane as busy when current bottom lines show active progress.
  if printf '%s\n' "$recent" | grep -Eqi '^[[:space:]]*◦[[:space:]].+'; then
    return 0
  fi

  printf '%s\n' "$recent" | grep -Eqi \
    'Working \(|Continuing workflow review|Running the requested|Thinking \(|Applying patch'
}

is_input_ready() {
  local text="$1"
  if is_busy "$text"; then
    return 1
  fi
  printf '%s\n' "$text" | tail -n 20 | grep -Eq '^[[:space:]]*›[[:space:]]'
}

queue_peek() {
  if [[ ! -f "$queue_file" ]]; then
    return 0
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    local trimmed
    trimmed="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [[ -z "$trimmed" || "$trimmed" =~ ^# ]]; then
      continue
    fi
    printf '%s\n' "$trimmed"
    return 0
  done < "$queue_file"
}

queue_pop() {
  if [[ ! -f "$queue_file" ]]; then
    return 0
  fi
  local tmp_file
  tmp_file="$(mktemp)"
  awk '
    BEGIN { popped=0 }
    {
      trimmed=$0
      gsub(/^[ \t]+/, "", trimmed)
      gsub(/[ \t]+$/, "", trimmed)
      if (!popped && trimmed != "" && substr(trimmed,1,1) != "#") {
        popped=1
        next
      }
      print $0
    }
  ' "$queue_file" > "$tmp_file"
  mv "$tmp_file" "$queue_file"
}

queue_contains_exact() {
  local needle="$1"
  [[ -f "$queue_file" ]] || return 1
  awk -v target="$needle" '
    {
      line=$0
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "" || substr(line, 1, 1) == "#") {
        next
      }
      if (line == target) {
        found=1
        exit
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$queue_file"
}

queue_prepend() {
  local item="$1"
  local tmp_file
  tmp_file="$(mktemp)"
  {
    printf '%s\n' "$item"
    if [[ -f "$queue_file" ]]; then
      cat "$queue_file"
    fi
  } > "$tmp_file"
  mv "$tmp_file" "$queue_file"
}

extract_composer_text() {
  local text="$1"
  printf '%s\n' "$text" \
    | sed -nE 's/^[[:space:]]*›[[:space:]]*(.*)$/\1/p' \
    | tail -n 1 \
    | sed -E 's/[[:space:]]+$//'
}

is_placeholder_composer_text() {
  local text="$1"
  case "$text" in
    ""|"Implement {feature}"|"Ask anything"|"Type a message"|"Summarize recent commits"|"Find and fix a bug in @filename"|"Use /skills to list available skills"|"Run /review on my current changes"|"Explain this codebase")
      return 0
      ;;
    *)
      # Codex rotates hint text in the composer (not real user input).
      if [[ "$text" =~ @filename$ ]]; then
        return 0
      fi
      if [[ "$text" =~ ^(Use|Run)[[:space:]]+/[a-z0-9-]+([[:space:]].*)?$ ]]; then
        return 0
      fi
      if [[ "$text" =~ ^(Find and fix a bug in @filename|Use /skills to list available skills|Run /review on my current changes|Summarize recent commits|Improve documentation in @filename)$ ]]; then
        return 0
      fi
      return 1
      ;;
  esac
}

composer_has_user_text() {
  local text="$1"
  if is_placeholder_composer_text "$text"; then
    return 1
  fi
  return 0
}

capture_tail_view() {
  tmux capture-pane -p -t "$pane_id" -S -260 2>/dev/null | tail -n 120
}

extract_resume_id_from_text() {
  local text="$1"
  printf '%s\n' "$text" \
    | sed -nE 's/.*codex resume ([A-Za-z0-9-]+).*/\1/p' \
    | tail -n 1
}

respawn_target_if_dead() {
  local snapshot="$1"
  local pane_dead pane_pid now_epoch resume_id respawn_cmd

  pane_dead="$(tmux display-message -p -t "$pane_id" "#{pane_dead}" 2>/dev/null || echo "0")"
  pane_pid="$(tmux display-message -p -t "$pane_id" "#{pane_pid}" 2>/dev/null || echo "")"
  if [[ "$pane_dead" != "1" ]]; then
    dead_pane_consecutive_count="0"
    return 1
  fi

  dead_pane_consecutive_count=$((dead_pane_consecutive_count + 1))
  if (( dead_pane_consecutive_count < dead_pane_consecutive_checks_required )); then
    log_line "target-pane-dead-detected target=$target pane_id=$pane_id pane_pid='${pane_pid:-none}' streak=$dead_pane_consecutive_count"
    return 0
  fi

  if [[ "$mode" != "supervisor" ]]; then
    log_line "target-pane-dead target=$target pane_id=$pane_id pane_pid='${pane_pid:-none}' mode=$mode"
    dead_pane_consecutive_count="0"
    return 0
  fi

  now_epoch="$(date +%s)"
  if (( now_epoch - last_respawn_epoch < respawn_retry_gap_seconds )); then
    log_line "target-pane-respawn-cooldown target=$target pane_id=$pane_id age=$((now_epoch - last_respawn_epoch))"
    return 0
  fi

  resume_id="$(extract_resume_id_from_text "$snapshot")"
  if [[ -n "$resume_id" ]]; then
    respawn_cmd="bash -lc 'cd \"$project_root\" && codex resume $resume_id'"
  else
    respawn_cmd="bash -lc 'cd \"$project_root\" && codex'"
  fi

  if [[ "$dry_run" == "true" ]]; then
    echo "[dry-run] respawn target pane: $respawn_cmd"
  else
    tmux respawn-pane -k -t "$pane_id" "$respawn_cmd"
  fi

  last_respawn_epoch="$now_epoch"
  stale_composer_text=""
  stale_composer_since_epoch="0"
  last_stale_clear_epoch="$now_epoch"
  dead_pane_consecutive_count="0"
  log_line "target-pane-respawn target=$target pane_id=$pane_id pane_pid='${pane_pid:-none}' resume_id='${resume_id:-none}'"
  sleep 2
  return 0
}

wait_for_clean_input() {
  local max_tries="${1:-24}"
  local sleep_seconds="${2:-0.25}"
  local i snap composer_now

  for ((i=0; i<max_tries; i++)); do
    snap="$(capture_tail_view)"
    if is_input_ready "$snap"; then
      composer_now="$(extract_composer_text "$snap")"
      if ! composer_has_user_text "$composer_now"; then
        return 0
      fi
    fi
    sleep "$sleep_seconds"
  done
  return 1
}

prepare_clean_composer() {
  local attempt composer_now
  if [[ "$dry_run" == "true" ]]; then
    return 0
  fi

  for attempt in 1 2 3; do
    composer_now="$(extract_composer_text "$(capture_tail_view)")"
    if ! composer_has_user_text "$composer_now"; then
      return 0
    fi
    tmux send-keys -t "$pane_id" Escape
    sleep 0.08
    tmux send-keys -t "$pane_id" C-u
    sleep 0.08
    tmux send-keys -t "$pane_id" C-a C-k
    sleep 0.08
  done

  composer_now="$(extract_composer_text "$(capture_tail_view)")"
  if composer_has_user_text "$composer_now"; then
    log_line "composer-clear-failed target=$target text='${composer_now//\'/\"}'"
    return 1
  fi
  return 0
}

recover_stale_composer_if_needed() {
  local text="$1"
  local now_epoch composer_text

  if [[ "$mode" != "supervisor" || "$dry_run" == "true" ]]; then
    return 1
  fi
  if is_busy "$text"; then
    return 1
  fi

  composer_text="$(extract_composer_text "$text")"
  if ! composer_has_user_text "$composer_text"; then
    stale_composer_text=""
    stale_composer_since_epoch="0"
    return 1
  fi

  now_epoch="$(date +%s)"
  if (( now_epoch - last_respawn_epoch < post_respawn_idle_seconds )); then
    return 1
  fi

  if [[ "$composer_text" != "$stale_composer_text" ]]; then
    stale_composer_text="$composer_text"
    stale_composer_since_epoch="$now_epoch"
    return 1
  fi

  if (( now_epoch - stale_composer_since_epoch < stale_composer_timeout_seconds )); then
    return 1
  fi
  if (( now_epoch - last_stale_clear_epoch < stale_composer_retry_gap_seconds )); then
    return 1
  fi

  if prepare_clean_composer; then
    log_line "stale-composer-cleared target=$target text='${composer_text//\'/\"}' age=$((now_epoch - stale_composer_since_epoch))"
    stale_composer_text=""
    stale_composer_since_epoch="0"
    last_stale_clear_epoch="$now_epoch"
    return 0
  fi

  log_line "stale-composer-clear-failed target=$target text='${composer_text//\'/\"}' age=$((now_epoch - stale_composer_since_epoch))"
  last_stale_clear_epoch="$now_epoch"
  return 0
}

send_supervised_command() {
  local cmd="$1"

  if [[ "$dry_run" == "true" ]]; then
    echo "[dry-run] supervised-command: $cmd"
    return 0
  fi

  if [[ "$cmd" =~ ^\$gsd- ]]; then
    if ! prepare_clean_composer; then
      return 1
    fi
    send_text_and_enter "/clear"
    log_line "auto-clear target=$target before_command='$cmd'"

    if ! wait_for_clean_input 28 0.25; then
      log_line "auto-clear-wait-timeout target=$target before_command='$cmd'"
      prepare_clean_composer || true
    fi
  fi

  if ! prepare_clean_composer; then
    return 1
  fi
  send_text_and_enter "$cmd"
}

dispatch_queue_if_ready() {
  local text="$1"
  local now_epoch cmd composer_text dispatched_cmd
  now_epoch="$(date +%s)"
  composer_text="$(extract_composer_text "$text")"

  # If we already dispatched a queue command, confirm it is accepted before
  # popping it and moving to the next one.
  if [[ -n "$pending_queue_command" ]]; then
    if [[ "$composer_text" == "$pending_queue_command" || "$composer_text" == "$pending_queue_command"* ]]; then
      if (( now_epoch - last_action_epoch >= min_action_gap_seconds )) && (( pending_submit_attempts < max_submit_attempts )); then
        log_line "queue-submit-retry target=$target command='$pending_queue_command' attempt=$((pending_submit_attempts + 1))"
        send_action "ENTER"
        pending_submit_attempts=$((pending_submit_attempts + 1))
        last_action_epoch="$now_epoch"
      fi
      return 0
    fi

    dispatched_cmd="$pending_queue_command"
    queue_pop
    log_line "queue-dispatch-ack target=$target command='$pending_queue_command' attempts=$pending_submit_attempts"
    pending_queue_command=""
    pending_submit_attempts="0"

    if [[ "$auto_verify" == "true" ]] && [[ "$dispatched_cmd" =~ ^\\$gsd-execute-phase[[:space:]]+[0-9]+([.][0-9]+)?([[:space:]]|$) ]]; then
      if ! queue_contains_exact "$verify_command"; then
        queue_prepend "$verify_command"
        log_line "auto-verify-enqueued target=$target after_command='$dispatched_cmd' verify='$verify_command'"
      fi
    fi
  fi

  cmd="$(queue_peek || true)"
  if [[ -z "$cmd" ]] || ! is_input_ready "$text"; then
    return 1
  fi

  if (( now_epoch - last_action_epoch < min_action_gap_seconds )); then
    return 1
  fi

  if composer_has_user_text "$composer_text"; then
    return 1
  fi

  if [[ "$dry_run" == "true" ]]; then
    echo "[dry-run] queue-dispatch: $cmd"
  else
    if ! send_supervised_command "$cmd"; then
      return 1
    fi
  fi
  log_line "queue-dispatch target=$target command='$cmd'"
  pending_queue_command="$cmd"
  pending_submit_attempts="1"
  last_action_epoch="$now_epoch"
  return 0
}

has_menu_prompt_context() {
  local text="$1"
  printf '%s\n' "$text" | grep -Eqi \
    'question[[:space:]]+[0-9]+/[0-9]+|\bchoose\b|\bselect\b|\bpick\b|your choice|enter.*number|type.*number|press.*number|which option|which .*option|unanswered|submit with unanswered questions\?|continue\?|pass/skip|issue|next up|what do you want to do'
}

extract_first_menu_option() {
  local text="$1"
  printf '%s\n' "$text" \
    | sed -nE 's/^[[:space:]]*(›[[:space:]]*)?([0-9]+)[.)—-][[:space:]]+.*$/\2/p' \
    | head -n 1
}

extract_recommended_menu_option() {
  local text="$1"
  printf '%s\n' "$text" \
    | sed -nE 's/^[[:space:]]*(›[[:space:]]*)?([0-9]+)[.)—-][[:space:]]+.*\(Recommended\).*/\2/p' \
    | head -n 1
}

is_prompt_candidate() {
  local text="$1"
  local recent
  recent="$(printf '%s\n' "$text" | tail -n 18)"

  if has_menu_prompt_context "$recent" && [[ -n "$(extract_first_menu_option "$recent")" ]]; then
    return 0
  fi

  printf '%s\n' "$recent" | grep -Eqi \
    'press enter to continue|press enter to confirm|hit enter to continue|\[[Yy]/[Nn]\]|\(yes/no\)|\byes/no\b|\bchoose\b|\bselect\b|\bpick\b|your choice|enter.*number|which option|which .*option|submit with unanswered questions\?|approval needed in|approval needed|do you want to approve|do you want me to|do you want to allow|allow this action|approve this action|requires approval|outside the sandbox|permission required|question[[:space:]]+[0-9]+/[0-9]+|unanswered|enter to submit answer|tab to add notes|also available|next up|what do you want to do'
}

hook_decision() {
  local text="$1"
  local selected_num recommended_num approval_agent

  if printf '%s\n' "$text" | grep -Eqi 'press enter to continue|press enter to confirm|hit enter to continue'; then
    echo "ENTER"
    return
  fi

  if printf '%s\n' "$text" | grep -Eq '\[[Yy]/[Nn]\]'; then
    echo "ENTER"
    return
  fi

  if printf '%s\n' "$text" | grep -Eqi '\(yes/no\)|\byes/no\b|\bY/N\b'; then
    echo "YES"
    return
  fi

  approval_agent="$(printf '%s\n' "$text" \
    | sed -nE 's/.*[Aa]pproval needed in ([^[]+)[[:space:]]+\[[^]]+\].*/\1/p' \
    | head -n 1 \
    | sed -E 's/[[:space:]]+$//')"
  if [[ -n "$approval_agent" ]]; then
    echo "AGENT:$approval_agent"
    return
  fi

  if printf '%s\n' "$text" | grep -Eqi 'approval needed|do you want to approve|do you want me to|do you want to allow|allow this action|approve this action|requires approval|outside the sandbox|permission required'; then
    echo "YES"
    return
  fi

  recommended_num="$(extract_recommended_menu_option "$text")"
  if [[ -n "$recommended_num" ]]; then
    echo "NUM:$recommended_num"
    return
  fi

  if has_menu_prompt_context "$text"; then
    selected_num="$(extract_first_menu_option "$text")"
    if [[ -n "$selected_num" ]]; then
      echo "NUM:$selected_num"
      return
    fi
  fi

  echo ""
}

run_self_tests() {
  local failures text action
  failures=0

  text=$'Sandbox approval required\nDo you want me to run this command outside the sandbox?'
  if ! is_prompt_candidate "$text"; then
    echo "FAIL: sandbox approval prompt was not detected"
    failures=$((failures + 1))
  fi
  action="$(hook_decision "$text")"
  if [[ "$action" != "YES" ]]; then
    echo "FAIL: sandbox approval should resolve to YES, got '$action'"
    failures=$((failures + 1))
  fi

  text=$'Permission required\nApprove this action to proceed'
  if ! is_prompt_candidate "$text"; then
    echo "FAIL: permission-required prompt was not detected"
    failures=$((failures + 1))
  fi
  action="$(hook_decision "$text")"
  if [[ "$action" != "YES" ]]; then
    echo "FAIL: permission-required prompt should resolve to YES, got '$action'"
    failures=$((failures + 1))
  fi

  text=$'Review complete. Press Enter to continue.'
  action="$(hook_decision "$text")"
  if [[ "$action" != "ENTER" ]]; then
    echo "FAIL: enter-to-continue prompt should resolve to ENTER, got '$action'"
    failures=$((failures + 1))
  fi

  text=$'! Approval needed in Mendel [gsd-debugger]\n› Implement {feature}'
  if ! is_prompt_candidate "$text"; then
    echo "FAIL: approval-needed banner prompt was not detected"
    failures=$((failures + 1))
  fi
  action="$(hook_decision "$text")"
  if [[ "$action" != "AGENT:Mendel" ]]; then
    echo "FAIL: approval-needed banner should route to AGENT:Mendel, got '$action'"
    failures=$((failures + 1))
  fi

  text="› Implement {feature}"
  if is_prompt_candidate "$text"; then
    echo "FAIL: composer placeholder text should not be treated as a prompt"
    failures=$((failures + 1))
  fi

  if [[ "$failures" -gt 0 ]]; then
    echo "Self-test failed: $failures case(s)"
    return 1
  fi

  echo "Self-test passed: sandbox approval prompt handling is healthy"
  return 0
}

strip_recommended_labels() {
  local text="$1"
  printf '%s\n' "$text" | sed -E 's/[[:space:]]*\([Rr]ecommended\)//g'
}

ai_raw_decision() {
  local text="$1"
  local out_file
  out_file="$(mktemp)"
  trap 'rm -f "$out_file"' RETURN

  if ! timeout 20s codex exec --color never -C "$project_root" -o "$out_file" - >/dev/null 2>&1 <<EOF; then
You are a strict terminal supervisor.
Choose only one token: ENTER | YES | NO | WAIT | <number>
If unsure, return WAIT.
Return exactly one token and nothing else.

Terminal excerpt:
$text
EOF
    echo ""
    return 1
  fi

  awk 'NF {print; exit}' "$out_file" | tr -d '\r'
}

supervisor_prompt_raw_decision() {
  local text="$1"
  local state_excerpt roadmap_excerpt de_biased_text
  local out_file
  out_file="$(mktemp)"
  trap 'rm -f "$out_file"' RETURN

  de_biased_text="$(strip_recommended_labels "$text")"
  state_excerpt="$(file_snippet "$project_root/.planning/STATE.md" 100)"
  roadmap_excerpt="$(file_snippet "$project_root/.planning/ROADMAP.md" 120)"

  if ! timeout 20s codex exec --color never -C "$project_root" -o "$out_file" - >/dev/null 2>&1 <<EOF; then
You are an analytical GSD supervisor answering an interactive terminal prompt.
Pick the single best action for project outcomes (quality, risk, roadmap alignment).

Output exactly one token and nothing else:
- ENTER
- YES
- NO
- WAIT
- <number>  (for numbered options)

Rules:
- Ignore any "(Recommended)" label in options; treat it as non-authoritative text.
- Use roadmap + current phase context to choose the highest-leverage option.
- If a numbered option is already selected and best, output ENTER.
- If uncertain, output WAIT.

Prompt excerpt:
$de_biased_text

STATE.md excerpt:
$state_excerpt

ROADMAP.md excerpt:
$roadmap_excerpt
EOF
    log_line "supervisor-prompt-model-failed target=$target" >/dev/null
    echo ""
    return 1
  fi

  awk 'NF {print; exit}' "$out_file" | tr -d '\r'
}

prompt_signature() {
  local text="$1"
  local stable_lines
  stable_lines="$(
    printf '%s\n' "$text" \
      | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' \
      | sed -E 's/[[:space:]]+\([0-9]+s.*\)$//' \
      | grep -Ei 'Question[[:space:]]+[0-9]+/[0-9]+|^[[:space:]]*[›]?[[:space:]]*[0-9]+[.)][[:space:]]|tab to add notes|enter to submit|which[[:space:]].*\?|if[[:space:]].*\?|do you want|approval needed in|approval needed|requires approval|outside the sandbox|permission required|allow this action|approve this action'
  )"
  if [[ -z "$stable_lines" ]]; then
    stable_lines="$(printf '%s\n' "$text" | tail -n 14)"
  fi
  printf '%s\n' "$stable_lines" | sha1sum | awk '{print $1}'
}

normalize_ai_action() {
  local raw="$1"
  local lower
  lower="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  case "$lower" in
    ""|wait)
      echo ""
      ;;
    enter)
      echo "ENTER"
      ;;
    yes|y)
      echo "YES"
      ;;
    no|n)
      echo "NO"
      ;;
    *)
      if [[ "$lower" =~ ^[0-9]+$ ]]; then
        echo "NUM:$lower"
      else
        echo ""
      fi
      ;;
  esac
}

file_snippet() {
  local file="$1"
  local max_lines="$2"
  if [[ ! -f "$file" ]]; then
    return 0
  fi
  sed -n "1,${max_lines}p" "$file" 2>/dev/null || true
}

latest_verification_path() {
  ls -1 "$project_root"/.planning/phases/*/*-VERIFICATION.md 2>/dev/null | sort | tail -n 1
}

canonicalize_gsd_command() {
  local raw="$1"
  local out
  out="$(printf '%s' "$raw" | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  out="$(printf '%s' "$out" | sed -E 's/^[0-9]+[.)][[:space:]]+//')"
  out="$(printf '%s' "$out" | sed -E 's/^`+//; s/`+$//')"
  out="$(printf '%s' "$out" | sed -E 's/[[:space:]]+$//')"
  printf '%s' "$out"
}

extract_explicit_gsd_command() {
  local text="$1"
  local cmd

  cmd="$(printf '%s\n' "$text" | awk '
    BEGIN { seen=0 }
    /Use this command:/ { seen=1; next }
    seen && /^[[:space:]]*\$gsd-[a-zA-Z0-9-]+([[:space:]].*)?$/ { print; exit }
  ')"

  if [[ -z "$cmd" ]]; then
    cmd="$(printf '%s\n' "$text" | awk '
      BEGIN { seen=0; budget=0 }
      /Next command:/ { seen=1; budget=8; next }
      seen {
        if (budget <= 0) { seen=0; next }
        if ($0 ~ /^[[:space:]]*$/) { budget--; next }
        if ($0 ~ /^[[:space:]]*[0-9]+[.)][[:space:]]+\$gsd-[a-zA-Z0-9-]+([[:space:]].*)?$/) {
          sub(/^[[:space:]]*[0-9]+[.)][[:space:]]+/, "", $0)
          print
          exit
        }
        if ($0 ~ /^[[:space:]]*\$gsd-[a-zA-Z0-9-]+([[:space:]].*)?$/) {
          sub(/^[[:space:]]+/, "", $0)
          print
          exit
        }
        budget--
      }
    ')"
  fi

  if [[ -z "$cmd" ]]; then
    cmd="$(printf '%s\n' "$text" | awk '
      BEGIN { seen=0 }
      /Next command:/ { seen=1; next }
      seen && /^[[:space:]]*[0-9]+[.)][[:space:]]+\$gsd-[a-zA-Z0-9-]+([[:space:]].*)?$/ {
        sub(/^[[:space:]]*[0-9]+[.)][[:space:]]+/, "", $0)
        print
        exit
      }
    ')"
  fi

  if [[ -z "$cmd" ]]; then
    cmd="$(printf '%s\n' "$text" | sed -nE 's/^[[:space:]]*([$]gsd-[a-zA-Z0-9-]+([[:space:]].*)?)$/\1/p' | tail -n 1)"
  fi

  canonicalize_gsd_command "$cmd"
}

convert_legacy_supervisor_message_to_gsd() {
  local raw="$1"
  local msg task escaped
  msg="$(printf '%s' "$raw" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

  if [[ "$msg" =~ ^Supervisor[[:space:]]+task:[[:space:]]*(.+)$ ]]; then
    task="${BASH_REMATCH[1]}"
    escaped="$(printf '%s' "$task" | sed -E 's/\\/\\\\/g; s/"/\\"/g')"
    printf '$gsd-quick --full "%s"' "$escaped"
    return
  fi

  if [[ "$msg" =~ ^Review[[:space:]]+loop:[[:space:]]*(.+)$ ]]; then
    task="review loop: ${BASH_REMATCH[1]}"
    escaped="$(printf '%s' "$task" | sed -E 's/\\/\\\\/g; s/"/\\"/g')"
    printf '$gsd-quick --full "%s"' "$escaped"
    return
  fi

  printf '%s' "$raw"
}

supervisor_raw_decision() {
  local pane_text="$1"
  local state_excerpt roadmap_excerpt verification_file verification_excerpt
  local out_file
  out_file="$(mktemp)"
  trap 'rm -f "$out_file"' RETURN

  state_excerpt="$(file_snippet "$project_root/.planning/STATE.md" "$supervisor_context_state_lines")"
  roadmap_excerpt="$(file_snippet "$project_root/.planning/ROADMAP.md" "$supervisor_context_roadmap_lines")"
  verification_file="$(latest_verification_path || true)"
  verification_excerpt=""
  if [[ -n "${verification_file:-}" ]]; then
    verification_excerpt="$(file_snippet "$verification_file" "$supervisor_context_verification_lines")"
  fi

  if ! timeout 45s codex exec --color never -C "$project_root" -o "$out_file" - >/dev/null 2>&1 <<EOF; then
You are an autonomous analytical supervisor for a codex tmux worker.
Your job is to decide the next best single step to advance the project toward roadmap goals.

Hard rules:
- Prefer WAIT unless there is a clear high-leverage next step.
- Never ask for generic status updates.
- Use a review loop before/after major changes: inspect diff, run tests/lints/checks, then fix issues.
- If work looks "done" but verification is missing/outdated, prioritize $gsd-verify-work before starting new phases.
- If verification says gaps_found, prioritize remediation over starting new phases.
- Output exactly three lines in this exact format:
ACTION: WAIT|SEND
MESSAGE: <single-line text or empty>
REASON: <short reason, <=140 chars>
- MESSAGE must be one line only and <= ${supervisor_max_message_chars} chars.
- MESSAGE must be a single executable command that starts with "\$gsd-".
- Never emit prose instructions or narrative text in MESSAGE.
- If complex work is needed, prefer "\$gsd-quick --full \"<task>\"" or "\$gsd-debug <issue>".
- Keep command shape strict, e.g. "\$gsd-plan-phase 3", "\$gsd-execute-phase 3", "\$gsd-quick --full \"run review loop for phase 2\"".
- Do not output anything else.

Current worker pane excerpt:
$pane_text

STATE.md excerpt:
$state_excerpt

ROADMAP.md excerpt:
$roadmap_excerpt

Latest verification file: ${verification_file:-"(none)"}
Verification excerpt:
$verification_excerpt
EOF
    log_line "supervisor-model-failed target=$target" >/dev/null
    return 1
  fi

  cat "$out_file"
}

supervisor_message_allowed() {
  local message="$1"
  local cmd cmd_name token_count second

  cmd="$(canonicalize_gsd_command "$message")"
  if [[ -z "$cmd" ]]; then
    return 1
  fi

  if [[ "${#cmd}" -gt "$supervisor_max_message_chars" ]]; then
    return 1
  fi
  if printf '%s' "$cmd" | grep -q '[[:cntrl:]]'; then
    return 1
  fi
  if printf '%s' "$cmd" | grep -q '`'; then
    return 1
  fi
  if ! [[ "$cmd" =~ ^\$gsd-[a-z0-9-]+([[:space:]].*)?$ ]]; then
    return 1
  fi
  if printf '%s' "$cmd" | grep -Eqi '\b(supervisor task|review loop)\b'; then
    return 1
  fi
  cmd_name="${cmd%% *}"
  token_count="$(awk '{print NF}' <<<"$cmd")"
  second="$(awk '{print $2}' <<<"$cmd")"

  case "$cmd_name" in
    \$gsd-quick|\$gsd-debug)
      # Permit richer task descriptions for quick/debug workflows.
      if (( token_count > 64 )); then
        return 1
      fi
      ;;
    \$gsd-execute-phase)
      if [[ -z "$second" || ! "$second" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        return 1
      fi
      if (( token_count > 3 )); then
        return 1
      fi
      ;;
    \$gsd-plan-phase|\$gsd-discuss-phase|\$gsd-research-phase)
      if [[ -n "$second" && ! "$second" =~ ^([0-9]+([.][0-9]+)?|--[a-z0-9-]+)$ ]]; then
        return 1
      fi
      if (( token_count > 12 )); then
        return 1
      fi
      ;;
    *)
      if printf '%s' "$cmd" | grep -Eq '[:;]'; then
        return 1
      fi
      if (( token_count > 10 )); then
        return 1
      fi
      ;;
  esac

  return 0
}

dispatch_supervisor_if_ready() {
  local text="$1"
  local now_epoch composer_text signature raw explicit_cmd decision_action decision_message decision_reason

  if [[ "$mode" != "supervisor" ]]; then
    return 1
  fi
  if [[ -n "$pending_queue_command" ]]; then
    return 1
  fi
  if [[ -n "$(queue_peek || true)" ]]; then
    return 1
  fi
  if ! is_input_ready "$text"; then
    return 1
  fi
  if is_prompt_candidate "$text"; then
    return 1
  fi

  now_epoch="$(date +%s)"
  if (( now_epoch - last_supervisor_epoch < supervisor_action_gap_seconds )); then
    return 1
  fi

  composer_text="$(extract_composer_text "$text")"
  if composer_has_user_text "$composer_text"; then
    return 1
  fi

  signature="$(printf '%s\n' "$text" | tail -n 18 | sha1sum | awk '{print $1}')"
  if [[ "$signature" == "$last_supervisor_signature" ]] && (( now_epoch - last_supervisor_epoch < supervisor_action_gap_seconds * 2 )); then
    return 1
  fi

  raw="$(supervisor_raw_decision "$text" || true)"
  decision_action="$(printf '%s\n' "$raw" | sed -nE 's/^ACTION:[[:space:]]*([A-Z]+).*$/\1/p' | head -n 1)"
  decision_message="$(printf '%s\n' "$raw" | sed -nE 's/^MESSAGE:[[:space:]]*(.*)$/\1/p' | head -n 1)"
  decision_reason="$(printf '%s\n' "$raw" | sed -nE 's/^REASON:[[:space:]]*(.*)$/\1/p' | head -n 1)"
  decision_message="$(convert_legacy_supervisor_message_to_gsd "$decision_message")"
  decision_message="$(canonicalize_gsd_command "$decision_message")"

  explicit_cmd="$(extract_explicit_gsd_command "$text")"
  if [[ -n "$explicit_cmd" ]]; then
    decision_action="SEND"
    decision_message="$explicit_cmd"
    if [[ -z "$decision_reason" ]]; then
      decision_reason="Worker surfaced an explicit next GSD command."
    fi
  fi

  if [[ "$decision_action" != "SEND" ]]; then
    log_line "supervisor-decision target=$target action=WAIT reason='${decision_reason//\'/\"}'"
    last_supervisor_signature="$signature"
    last_supervisor_epoch="$now_epoch"
    return 0
  fi

  if ! supervisor_message_allowed "$decision_message"; then
    log_line "supervisor-decision target=$target action=DROP_INVALID reason='${decision_reason//\'/\"}'"
    last_supervisor_signature="$signature"
    last_supervisor_epoch="$now_epoch"
    return 0
  fi

  if [[ "$decision_message" == "$last_supervisor_message" ]] && (( now_epoch - last_supervisor_epoch < supervisor_action_gap_seconds * 3 )); then
    log_line "supervisor-decision target=$target action=DROP_DUPLICATE reason='${decision_reason//\'/\"}'"
    last_supervisor_signature="$signature"
    last_supervisor_epoch="$now_epoch"
    return 0
  fi

  if ! send_supervised_command "$decision_message"; then
    return 1
  fi
  log_line "supervisor-dispatch target=$target message='${decision_message//\'/\"}' reason='${decision_reason//\'/\"}'"
  last_supervisor_message="$decision_message"
  last_supervisor_signature="$signature"
  last_supervisor_epoch="$now_epoch"
  last_action_epoch="$now_epoch"
  return 0
}

if [[ "$self_test" == "true" ]]; then
  run_self_tests
  exit $?
fi

while true; do
  pane_id="$(tmux display-message -p -t "$target" "#{pane_id}" 2>/dev/null || true)"
  if [[ -z "$pane_id" ]]; then
    echo "Target no longer exists: $target"
    exit 0
  fi

  snapshot="$(tmux capture-pane -p -t "$pane_id" -S -240 || true)"
  if respawn_target_if_dead "$snapshot"; then
    last_hash=""
    last_prompt_signature=""
    sleep "$interval"
    continue
  fi
  current_hash="$(printf '%s' "$snapshot" | sha1sum | awk '{print $1}')"
  tail_view="$(printf '%s\n' "$snapshot" | tail -n 120)"

  recover_stale_composer_if_needed "$tail_view" || true

  # Queue has priority and should be checked every loop, even if pane output
  # is unchanged, so sequenced commands don't stall.
  dispatch_queue_if_ready "$tail_view" || true
  dispatch_supervisor_if_ready "$tail_view" || true

  if [[ -z "$pending_queue_command" ]] && is_prompt_candidate "$tail_view"; then
    signature="$(prompt_signature "$tail_view")"
    if [[ "$signature" != "$last_prompt_signature" ]]; then
      action=""
      raw_decision=""
      prompt_view="$tail_view"

      if [[ "$mode" == "supervisor" ]]; then
        prompt_view="$(strip_recommended_labels "$tail_view")"
      fi

      if [[ "$mode" == "ai" ]]; then
        raw_decision="$(ai_raw_decision "$prompt_view" || true)"
        action="$(normalize_ai_action "$raw_decision")"
      elif [[ "$mode" == "supervisor" ]]; then
        raw_decision="$(supervisor_prompt_raw_decision "$prompt_view" || true)"
        action="$(normalize_ai_action "$raw_decision")"
      fi

      if [[ -z "$action" && "$mode" == "supervisor" ]]; then
        if [[ "$(printf '%s' "$raw_decision" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')" == "wait" ]]; then
          action=""
        else
          action="$(hook_decision "$prompt_view")"
        fi
      elif [[ -z "$action" ]]; then
        action="$(hook_decision "$prompt_view")"
      fi

      if [[ -n "$action" ]]; then
        now_epoch="$(date +%s)"
        if [[ "$action" == AGENT:* ]]; then
          agent_name="${action#AGENT:}"
          if [[ -n "$agent_name" && "$agent_name" == "$last_agent_target" ]] && (( now_epoch - last_agent_target_epoch < agent_route_repeat_gap_seconds )); then
            log_line "prompt-detected target=$target action=SKIP_AGENT_REPEAT ai_raw='${raw_decision:-}'"
            last_prompt_signature="$signature"
            continue
          fi
        fi
        if [[ "$action" == AGENT:* ]] && (( now_epoch - last_agent_route_epoch < agent_route_gap_seconds )); then
          log_line "prompt-detected target=$target action=SKIP_AGENT_COOLDOWN ai_raw='${raw_decision:-}'"
          last_prompt_signature="$signature"
        elif (( now_epoch - last_action_epoch >= min_action_gap_seconds )); then
          log_line "prompt-detected target=$target action=$action ai_raw='${raw_decision:-}'"
          send_action "$action"
          last_action_epoch="$now_epoch"
          if [[ "$action" == AGENT:* ]]; then
            last_agent_route_epoch="$now_epoch"
            last_agent_target="${action#AGENT:}"
            last_agent_target_epoch="$now_epoch"
          fi
          last_prompt_signature="$signature"
        else
          log_line "prompt-detected target=$target action=SKIP_COOLDOWN ai_raw='${raw_decision:-}'"
        fi
      else
        log_line "prompt-detected target=$target action=WAIT ai_raw='${raw_decision:-}'"
        last_prompt_signature="$signature"
      fi
    fi
  else
    last_prompt_signature=""
  fi

  last_hash="$current_hash"
  sleep "$interval"
done
