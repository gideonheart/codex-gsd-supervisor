#!/usr/bin/env bash
set -euo pipefail

developer_session="${1:-}"
driver_session="${2:-}"
state_dir="${3:-}"

if [[ -z "$developer_session" || -z "$driver_session" || -z "$state_dir" ]]; then
  echo "Usage: scripts/codex-duet-bridge.sh <developer-session> <driver-session> <state-dir>" >&2
  exit 2
fi

LOG_FILE="$state_dir/duet-bridge.log"
mkdir -p "$state_dir"
touch "$LOG_FILE"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

developer_seen="$state_dir/developer.seen"
driver_seen="$state_dir/driver.seen"
touch "$developer_seen" "$driver_seen"

normalize() {
  sed 's/\r//g' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

capture_directive_lines() {
  local source="$1"
  local target_prefix="$2"
  local output="$3"
  : > "$output"

  if ! tmux has-session -t "$source" 2>/dev/null; then
    return 0
  fi

  local snapshot="$tmp_dir/snapshot.txt"
  local cleaned="$tmp_dir/cleaned.txt"
  if ! tmux capture-pane -p -J -t "$source" -S -240 > "$snapshot" 2>/dev/null; then
    return 0
  fi

  sed 's/\r//g' "$snapshot" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' > "$cleaned"
  grep -a -o "TO=${target_prefix}:[[:space:]]*.*" "$cleaned" \
    | normalize > "$output" || true
}

send_once() {
  local source_session="$1"
  local target_session="$2"
  local msg="$3"
  local seen_file="$4"
  local tag="$5"

  if tmux has-session -t "$target_session" 2>/dev/null; then
    tmux send-keys -t "$target_session" -l "$msg"
    tmux send-keys -t "$target_session" Enter
    printf '[%s] %s forward "%s"\n' "$(date '+%F %T')" "$tag" "$msg" >> "$LOG_FILE"
    printf '%s\n' "$msg" >> "$seen_file"
    if (( $(wc -l < "$seen_file") > 240 )); then
      tail -n 240 "$seen_file" > "$seen_file.tmp" && mv "$seen_file.tmp" "$seen_file"
    fi
  else
    printf '[%s] %s target missing: %s\n' "$(date '+%F %T')" "$tag" "$target_session" >> "$LOG_FILE"
  fi
}

forward_from_source() {
  local source_session="$1"
  local prefix="$2"
  local seen_file="$3"
  local target_session="$4"
  local tag="$5"

  local snapshot="$tmp_dir/normalized.txt"
  capture_directive_lines "$source_session" "$prefix" "$snapshot"
  [[ -s "$snapshot" ]] || return 0

  while IFS= read -r line; do
    if [[ -z "$line" ]]; then
      continue
    fi
    if grep -Fxq "$line" "$seen_file" 2>/dev/null; then
      continue
    fi
    send_once "$source_session" "$target_session" "$line" "$seen_file" "$tag"
  done < "$snapshot"
}

while true; do
  forward_from_source "$driver_session" "developer" "$developer_seen" "$developer_session" "driver->developer"
  forward_from_source "$developer_session" "driver" "$driver_seen" "$driver_session" "developer->driver"
  sleep 1
done
