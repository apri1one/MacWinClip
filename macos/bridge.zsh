#!/bin/zsh
set -u
setopt pipe_fail
setopt extended_glob
umask 077

config="$HOME/.config/mac-windows-ssh-clipboard/config.zsh"
if [[ ! -f "$config" ]]; then
  print -u2 -- "Missing config: $config"
  exit 1
fi
source "$config"

if [[ ! -x "$CLIPBOARD_HELPER" ]]; then
  print -u2 -- "Missing clipboard helper: $CLIPBOARD_HELPER"
  exit 1
fi

runtime_dir="$HOME/Library/Caches/mac-windows-ssh-clipboard"
outbound_file="$runtime_dir/outbound.payload"
inbound_file="$runtime_dir/inbound.payload"
mkdir -p "$runtime_dir"
chmod 700 "$runtime_dir"

cleanup() {
  rm -f "$outbound_file" "$inbound_file"
}
trap cleanup EXIT
trap 'cleanup; exit 0' HUP INT TERM

ssh_options=(
  -T
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o ClearAllForwardings=yes
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
)

scp_options=(
  -q
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o ClearAllForwardings=yes
)

remote_action_command() {
  local action="$1"
  shift
  print -r -- "powershell -NoProfile -ExecutionPolicy Bypass -File \"$WINDOWS_REMOTE_SCRIPT\" $action $*"
}

clipboard_change_count() {
  "$CLIPBOARD_HELPER" change-count 2>/dev/null
}

type_limit() {
  if [[ "$1" == "PNG" ]]; then
    print -r -- "${MAX_IMAGE_BYTES:-16777216}"
  else
    print -r -- "${MAX_TEXT_BYTES:-1048576}"
  fi
}

queue_current_clipboard() {
  local metadata payload_count payload_type payload_size max_bytes message_id
  local -a metadata_parts

  metadata="$("$CLIPBOARD_HELPER" export "$outbound_file" 2>/dev/null)" || return 1
  metadata_parts=("${(@s: :)metadata}")
  if (( ${#metadata_parts} != 3 )); then
    return 1
  fi

  payload_count="${metadata_parts[1]}"
  payload_type="${metadata_parts[2]}"
  payload_size="${metadata_parts[3]}"
  if [[ "$payload_count" != <-> || "$payload_size" != <-> ]]; then
    return 1
  fi
  last_change_count="$payload_count"

  if [[ "$payload_type" == "EMPTY" || "$payload_size" == "0" ]]; then
    pending_id=""
    pending_type=""
    rm -f "$outbound_file"
    return 0
  fi
  if [[ "$payload_type" != "TEXT" && "$payload_type" != "PNG" ]]; then
    rm -f "$outbound_file"
    return 1
  fi

  max_bytes="$(type_limit "$payload_type")"
  if (( payload_size > max_bytes )); then
    pending_id=""
    pending_type=""
    rm -f "$outbound_file"
    return 0
  fi

  message_id="$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')" || return 1
  pending_id="$message_id"
  pending_type="$payload_type"
  pending_retry_ticks=0
}

send_pending_to_windows() {
  local type_name remote_upload response

  if [[ -z "$pending_id" || -z "$pending_type" || ! -f "$outbound_file" ]]; then
    return 1
  fi

  type_name="${(L)pending_type}"
  remote_upload="$WINDOWS_SCP_ROOT/upload.$pending_id.$type_name.tmp"
  scp "${scp_options[@]}" "$outbound_file" "$SSH_TARGET:$remote_upload" || return 1

  response="$(ssh "${ssh_options[@]}" "$SSH_TARGET" \
    "$(remote_action_command receive "$pending_id" "$pending_type")" 2>/dev/null)" || return 1
  response="${response%$'\r'}"
  if [[ "$response" != "ACK $pending_id" ]]; then
    return 1
  fi

  pending_id=""
  pending_type=""
  rm -f "$outbound_file"
  return 0
}

ack_windows_message() {
  local message_id="$1"
  local response

  response="$(ssh "${ssh_options[@]}" "$SSH_TARGET" \
    "$(remote_action_command ack "$message_id")" 2>/dev/null)" || return 1
  response="${response%$'\r'}"
  [[ "$response" == "ACK $message_id" ]]
}

receive_protocol_line() {
  local line="$1"
  local remainder message_id payload_type encoded payload_size max_bytes max_encoded new_count

  if [[ "$line" == "PING" || "$line" != SET\ *\ *\ * ]]; then
    return
  fi

  remainder="${line#SET }"
  message_id="${remainder%% *}"
  remainder="${remainder#* }"
  payload_type="${remainder%% *}"
  encoded="${remainder#* }"

  if [[ ${#message_id} -ne 32 || "$message_id" != [a-f0-9]## ]]; then
    return
  fi
  if [[ "$payload_type" != "TEXT" && "$payload_type" != "PNG" ]]; then
    return
  fi

  if [[ "$message_id" == "$last_received_id" ]]; then
    ack_windows_message "$message_id" || true
    return
  fi

  max_bytes="$(type_limit "$payload_type")"
  max_encoded=$(( ((max_bytes + 2) / 3) * 4 + 4 ))
  if (( ${#encoded} > max_encoded )); then
    return
  fi
  if ! print -rn -- "$encoded" | base64 -D > "$inbound_file" 2>/dev/null; then
    rm -f "$inbound_file"
    return
  fi

  payload_size="$(wc -c < "$inbound_file" | tr -d ' ')"
  if [[ "$payload_size" != <-> ]] || (( payload_size == 0 || payload_size > max_bytes )); then
    rm -f "$inbound_file"
    return
  fi

  new_count="$("$CLIPBOARD_HELPER" import "$payload_type" "$inbound_file" 2>/dev/null)" || {
    rm -f "$inbound_file"
    return
  }
  rm -f "$inbound_file"
  if [[ "$new_count" == <-> ]]; then
    last_change_count="$new_count"
    last_received_id="$message_id"
    ack_windows_message "$message_id" || true
  fi
}

last_change_count=""
until last_change_count="$(clipboard_change_count)" && [[ "$last_change_count" == <-> ]]; do
  sleep 1
done
pending_id=""
pending_type=""
pending_retry_ticks=0
last_received_id=""

while true; do
  coproc ssh "${ssh_options[@]}" "$SSH_TARGET" "$(remote_action_command stream)"
  ssh_pid=$!

  while kill -0 "$ssh_pid" 2>/dev/null; do
    while IFS= read -r -t 0.01 -p protocol_line; do
      protocol_line="${protocol_line%$'\r'}"
      receive_protocol_line "$protocol_line"
    done

    if current_change_count="$(clipboard_change_count)" &&
       [[ "$current_change_count" == <-> && "$current_change_count" != "$last_change_count" ]]; then
      queue_current_clipboard || true
    fi

    if [[ -n "$pending_id" ]]; then
      if (( pending_retry_ticks <= 0 )); then
        send_pending_to_windows || true
        pending_retry_ticks=5
      else
        (( pending_retry_ticks -= 1 ))
      fi
    fi

    sleep "${CLIPBOARD_CHECK_INTERVAL:-0.2}"
  done

  wait "$ssh_pid" 2>/dev/null || true
  sleep "${RECONNECT_INTERVAL:-1}"
done
