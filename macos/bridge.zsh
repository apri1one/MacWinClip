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

ssh_options=(
  -T
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o ClearAllForwardings=yes
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
)

remote_command() {
  print -r -- "powershell -NoProfile -ExecutionPolicy Bypass -File \"$WINDOWS_REMOTE_SCRIPT\" stream"
}

clipboard_hash() {
  pbpaste 2>/dev/null | shasum -a 256 | awk '{print $1}'
}

queue_current_clipboard() {
  local current_hash="$1"
  local current_size encoded message_id

  current_size="$(pbpaste 2>/dev/null | wc -c | tr -d ' ')"
  if [[ "$current_size" == "0" || "$current_size" -gt 1048576 ]]; then
    last_hash="$current_hash"
    pending_id=""
    pending_frame=""
    return
  fi

  encoded="$(pbpaste 2>/dev/null | base64 | tr -d '\r\n')" || return
  message_id="$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')" || return
  pending_id="$message_id"
  pending_frame="SET $message_id $encoded"
  last_hash="$current_hash"
}

receive_protocol_line() {
  local line="$1"
  local remainder message_id encoded inbound_hash

  if [[ "$line" == ACK\ * ]]; then
    message_id="${line#ACK }"
    if [[ "$message_id" == "$pending_id" ]]; then
      pending_id=""
      pending_frame=""
    fi
    return
  fi

  if [[ "$line" != SET\ *\ * ]]; then
    return
  fi

  remainder="${line#SET }"
  message_id="${remainder%% *}"
  encoded="${remainder#* }"
  if [[ ${#message_id} -ne 32 || "$message_id" != [a-f0-9]## ]]; then
    return
  fi

  inbound_hash="$(print -rn -- "$encoded" | base64 -D 2>/dev/null | shasum -a 256 | awk '{print $1}')" || return
  if print -rn -- "$encoded" | base64 -D 2>/dev/null | pbcopy; then
    last_hash="$inbound_hash"
    print -r -p -- "ACK $message_id"
  fi
}

last_hash=""
until last_hash="$(clipboard_hash)"; do
  sleep 1
done
pending_id=""
pending_frame=""

while true; do
  coproc ssh "${ssh_options[@]}" "$SSH_TARGET" "$(remote_command)"
  ssh_pid=$!
  if [[ -n "$pending_frame" ]]; then
    print -r -p -- "$pending_frame" || true
  fi

  while kill -0 "$ssh_pid" 2>/dev/null; do
    while IFS= read -r -t 0.01 -p protocol_line; do
      receive_protocol_line "$protocol_line"
    done

    if current_hash="$(clipboard_hash)" && [[ "$current_hash" != "$last_hash" ]]; then
      queue_current_clipboard "$current_hash"
      if [[ -n "$pending_frame" ]]; then
        print -r -p -- "$pending_frame" || true
      fi
    fi

    sleep "${CLIPBOARD_CHECK_INTERVAL:-0.2}"
  done

  wait "$ssh_pid" 2>/dev/null || true
  sleep "${RECONNECT_INTERVAL:-1}"
done
