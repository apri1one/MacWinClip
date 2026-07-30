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
transfer_dir="$runtime_dir/transfers"
completion_dir="$runtime_dir/completed"
outbound_file="$runtime_dir/outbound.payload"
inbound_file="$runtime_dir/inbound.payload"
health_state_file="$runtime_dir/health.json"
health_log_file="$runtime_dir/health.jsonl"
mkdir -p "$runtime_dir" "$transfer_dir" "$completion_dir"
chmod 700 "$runtime_dir" "$transfer_dir" "$completion_dir"

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  print -rn -- "$value"
}

rotate_health_log() {
  local size
  [[ -f "$health_log_file" ]] || return 0
  size="$(wc -c < "$health_log_file" | tr -d ' ')" || return 0
  if [[ "$size" == <-> ]] && (( size >= ${HEALTH_LOG_MAX_BYTES:-1048576} )); then
    mv -f "$health_log_file" "$health_log_file.1"
  fi
}

log_health_event() {
  local level="$1"
  local event="$2"
  local state="$3"
  local failures="$4"
  local detail="$5"
  local timestamp
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  rotate_health_log
  printf '{"timestampUtc":"%s","level":"%s","event":"%s","state":"%s","failures":%s,"detail":"%s"}\n' \
    "$(json_escape "$timestamp")" \
    "$(json_escape "$level")" \
    "$(json_escape "$event")" \
    "$(json_escape "$state")" \
    "$failures" \
    "$(json_escape "$detail")" \
    >> "$health_log_file"
  chmod 600 "$health_log_file"
}

write_health_state() {
  local state="$1"
  local failures="$2"
  local next_retry_seconds="$3"
  local detail="$4"
  local timestamp temporary
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  temporary="$health_state_file.tmp"
  printf '{"updatedUtc":"%s","state":"%s","failures":%s,"nextRetrySeconds":%s,"detail":"%s"}\n' \
    "$(json_escape "$timestamp")" \
    "$(json_escape "$state")" \
    "$failures" \
    "$next_retry_seconds" \
    "$(json_escape "$detail")" \
    > "$temporary"
  chmod 600 "$temporary"
  mv -f "$temporary" "$health_state_file"
}

cleanup() {
  local pid_file message_id attempt owner_pid
  local -a worker_pid_files owner_pid_files

  worker_pid_files=("$transfer_dir"/*.worker.pid(N))
  for pid_file in "${worker_pid_files[@]}"; do
    message_id="${pid_file:t:r:r}"
    if [[ ${#message_id} -eq 32 && "$message_id" == [a-f0-9]## ]]; then
      print -r -- "cancel" > "$transfer_dir/$message_id.cancel"
    fi
  done
  for attempt in {1..30}; do
    worker_pid_files=("$transfer_dir"/*.worker.pid(N))
    (( ${#worker_pid_files} == 0 )) && break
    sleep 0.1
  done
  owner_pid_files=("$transfer_dir"/*.owner.pid(N))
  for pid_file in "${owner_pid_files[@]}"; do
    owner_pid="$(<"$pid_file")"
    if [[ "$owner_pid" == <-> ]] &&
       ps -p "$owner_pid" -o command= 2>/dev/null |
         grep -Fq -- "$CLIPBOARD_HELPER own-files"; then
      kill "$owner_pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  done
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

remote_action() {
  ssh "${ssh_options[@]}" "$SSH_TARGET" \
    "$(remote_action_command "$@")" 2>/dev/null
}

remote_action_with_timeout() {
  local timeout_seconds="$1"
  shift
  /usr/bin/perl -e \
    'my $timeout = shift @ARGV; alarm $timeout; exec @ARGV' \
    "$timeout_seconds" \
    ssh "${ssh_options[@]}" "$SSH_TARGET" \
    "$(remote_action_command "$@")" 2>/dev/null
}

windows_health_check() {
  local response
  response="$(remote_action_with_timeout "${HEALTH_COMMAND_TIMEOUT:-8}" health)" || return 1
  response="${response%$'\r'}"
  [[ "$response" =~ '^OK V[0-9]+ [1-9][0-9]*$' ]]
}

request_windows_recovery() {
  local response
  response="$(remote_action_with_timeout "${HEALTH_COMMAND_TIMEOUT:-8}" recover)" || return 1
  response="${response%$'\r'}"
  [[ "$response" == "RECOVERY REQUESTED" ]]
}

clipboard_change_count() {
  "$CLIPBOARD_HELPER" change-count 2>/dev/null
}

type_limit() {
  if [[ "$1" == "PNG" ]]; then
    print -r -- "${MAX_IMAGE_BYTES:-16777216}"
  elif [[ "$1" == "FILES" ]]; then
    print -r -- "${MAX_MANIFEST_BYTES:-1048576}"
  else
    print -r -- "${MAX_TEXT_BYTES:-1048576}"
  fi
}

queue_current_clipboard() {
  local metadata payload_count payload_type payload_size max_bytes message_id private_manifest
  local offer_manifest
  local -a metadata_parts active_manifests

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
  drop_file_offer

  if [[ "$payload_type" == "EMPTY" || "$payload_size" == "0" ]]; then
    pending_id=""
    pending_type=""
    rm -f "$outbound_file"
    return 0
  fi
  if [[ "$payload_type" != "TEXT" && "$payload_type" != "PNG" && "$payload_type" != "FILES" ]]; then
    rm -f "$outbound_file"
    return 1
  fi

  if [[ "$payload_type" == "FILES" ]]; then
    if (( payload_size > ${MAX_FILE_BYTES:-10737418240} )); then
      rm -f "$outbound_file"
      return 0
    fi
    active_manifests=("$transfer_dir"/*.private.json(N))
    if (( ${#active_manifests} > 0 )); then
      rm -f "$outbound_file"
      return 0
    fi
    message_id="$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')" || return 1
    "$CLIPBOARD_HELPER" set-id "$outbound_file" "$message_id" 2>/dev/null || {
      rm -f "$outbound_file"
      return 1
    }
    private_manifest="$transfer_dir/$message_id.private.json"
    mv -f "$outbound_file" "$private_manifest"
    offer_manifest="$transfer_dir/$message_id.public.json"
    "$CLIPBOARD_HELPER" offer-manifest "$private_manifest" "$offer_manifest" 2>/dev/null || {
      rm -f "$private_manifest" "$offer_manifest"
      return 1
    }
    file_offer_id="$message_id"
    file_offer_private="$private_manifest"
    file_offer_public="$offer_manifest"
    file_offer_retry_ticks=0
    file_offer_announced=0
    pending_id=""
    pending_type=""
    return 0
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

drop_file_offer() {
  local drop_id response

  drop_id="$remote_file_clipboard_id"
  if [[ -z "$drop_id" ]]; then
    drop_id="$file_offer_id"
  fi
  if [[ -z "$drop_id" ]]; then
    return 0
  fi
  remote_file_drop_pending=1
  response="$(ssh "${ssh_options[@]}" "$SSH_TARGET" \
    "$(remote_action_command drop-offer "$drop_id")" 2>/dev/null)" || true
  response="${response%$'\r'}"
  rm -f "$file_offer_private" "$file_offer_public"
  file_offer_id=""
  file_offer_private=""
  file_offer_public=""
  file_offer_retry_ticks=0
  file_offer_announced=0
  if [[ "$response" == "ACK $drop_id" ]]; then
    if [[ "$remote_file_clipboard_id" == "$drop_id" ]]; then
      remote_file_clipboard_id=""
    fi
    remote_file_drop_pending=0
    remote_file_drop_retry_ticks=0
  else
    remote_file_drop_retry_ticks=5
  fi
}

retry_remote_file_drop() {
  local drop_id response

  if [[ "$remote_file_drop_pending" != "1" || -z "$remote_file_clipboard_id" ]]; then
    return 0
  fi
  drop_id="$remote_file_clipboard_id"
  response="$(ssh "${ssh_options[@]}" "$SSH_TARGET" \
    "$(remote_action_command drop-offer "$drop_id")" 2>/dev/null)" || return 1
  response="${response%$'\r'}"
  if [[ "$response" == "ACK $drop_id" && "$remote_file_clipboard_id" == "$drop_id" ]]; then
    remote_file_clipboard_id=""
    remote_file_drop_pending=0
    remote_file_drop_retry_ticks=0
    return 0
  fi
  return 1
}

send_file_offer() {
  local remote_upload response

  if [[ -z "$file_offer_id" || ! -f "$file_offer_public" ]]; then
    return 1
  fi
  remote_upload="$WINDOWS_SCP_ROOT/upload.$file_offer_id.files.tmp"
  scp "${scp_options[@]}" "$file_offer_public" "$SSH_TARGET:$remote_upload" || return 1
  response="$(ssh "${ssh_options[@]}" "$SSH_TARGET" \
    "$(remote_action_command offer-files "$file_offer_id")" 2>/dev/null)" || return 1
  response="${response%$'\r'}"
  if [[ "$response" == "OFFERED $file_offer_id" ]]; then
    file_offer_announced=1
    remote_file_clipboard_id="$file_offer_id"
    remote_file_drop_pending=0
    remote_file_drop_retry_ticks=0
    return 0
  fi
  return 1
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
  local manifest_total received_manifest

  if [[ "$line" == FETCH\ [a-f0-9]## ]]; then
    message_id="${line#FETCH }"
    if [[ ${#message_id} -eq 32 &&
          "$message_id" == "$file_offer_id" &&
          -f "$file_offer_private" &&
          ! -f "$transfer_dir/$message_id.worker.pid" ]]; then
      zsh "$FILE_TRANSFER_SCRIPT" send \
        "$message_id" "$file_offer_private" >/dev/null 2>&1 &!
      file_offer_id=""
      file_offer_private=""
      file_offer_public=""
      file_offer_retry_ticks=0
      file_offer_announced=0
    fi
    return
  fi

  if [[ "$line" == DISMISS\ [a-f0-9]## ]]; then
    message_id="${line#DISMISS }"
    if [[ ${#message_id} -eq 32 && "$message_id" == "$remote_file_clipboard_id" ]]; then
      remote_file_clipboard_id=""
      remote_file_drop_pending=0
      remote_file_drop_retry_ticks=0
    fi
    if [[ ${#message_id} -eq 32 && "$message_id" == "$file_offer_id" ]]; then
      rm -f "$file_offer_private" "$file_offer_public"
      file_offer_id=""
      file_offer_private=""
      file_offer_public=""
      file_offer_retry_ticks=0
      file_offer_announced=0
    fi
    return
  fi

  if [[ "$line" == CANCEL\ [a-f0-9]## ]]; then
    message_id="${line#CANCEL }"
    if [[ ${#message_id} -eq 32 ]]; then
      print -r -- "cancel" > "$transfer_dir/$message_id.cancel"
    fi
    return
  fi

  if [[ "$line" == "PING" ]]; then
    last_protocol_tick=$SECONDS
    return
  fi
  if [[ "$line" != SET\ *\ *\ * ]]; then
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
  if [[ "$payload_type" != "TEXT" && "$payload_type" != "PNG" && "$payload_type" != "FILES" ]]; then
    return
  fi

  if [[ "$message_id" == "$last_received_id" ]]; then
    ack_windows_message "$message_id" || true
    return
  fi
  if [[ "$payload_type" == "FILES" && "$message_id" == "$active_receive_id" ]]; then
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

  if [[ "$payload_type" == "FILES" ]]; then
    manifest_total="$("$CLIPBOARD_HELPER" manifest-total "$inbound_file" 2>/dev/null)" || {
      rm -f "$inbound_file"
      return
    }
    if [[ "$manifest_total" != <-> ]] || (( manifest_total <= 0 || manifest_total > ${MAX_FILE_BYTES:-10737418240} )); then
      rm -f "$inbound_file"
      return
    fi
    received_manifest="$transfer_dir/$message_id.public.json"
    mv -f "$inbound_file" "$received_manifest"
    active_receive_id="$message_id"
    zsh "$FILE_TRANSFER_SCRIPT" receive "$message_id" "$received_manifest" >/dev/null 2>&1 &!
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

process_file_completions() {
  local completion message_id new_count

  for completion in "$completion_dir"/*.count(N); do
    message_id="${completion:t:r}"
    if [[ ${#message_id} -ne 32 || "$message_id" != [a-f0-9]## ]]; then
      rm -f "$completion"
      continue
    fi
    new_count="$(<"$completion")"
    if [[ "$new_count" == <-> ]]; then
      last_change_count="$new_count"
      last_received_id="$message_id"
    fi
    [[ "$active_receive_id" == "$message_id" ]] && active_receive_id=""
    rm -f "$completion"
  done
  for completion in "$completion_dir"/*.failed(N); do
    message_id="${completion:t:r}"
    [[ "$active_receive_id" == "$message_id" ]] && active_receive_id=""
    rm -f "$completion"
  done
}

last_change_count=""
until last_change_count="$(clipboard_change_count)" && [[ "$last_change_count" == <-> ]]; do
  sleep 1
done
pending_id=""
pending_type=""
pending_retry_ticks=0
file_offer_id=""
file_offer_private=""
file_offer_public=""
file_offer_retry_ticks=0
file_offer_announced=0
remote_file_clipboard_id=""
remote_file_drop_pending=0
remote_file_drop_retry_ticks=0
last_received_id=""
active_receive_id=""

health_interval="${HEALTH_CHECK_INTERVAL:-15}"
protocol_timeout="${PROTOCOL_TIMEOUT:-20}"
health_failure_threshold="${HEALTH_FAILURE_THRESHOLD:-3}"
reconnect_max_interval="${RECONNECT_MAX_INTERVAL:-300}"
recovery_base_interval="${RECOVERY_BASE_INTERVAL:-10}"
recovery_max_interval="${RECOVERY_MAX_INTERVAL:-300}"
health_failures=0
reconnect_failures=0
recovery_interval="$recovery_base_interval"
next_recovery_tick=0
write_health_state "starting" 0 0 "bridge_starting"
log_health_event "info" "bridge_started" "starting" 0 "bridge_starting"

while true; do
  session_healthy=0
  last_protocol_tick=$SECONDS
  next_health_tick=$(( SECONDS + 1 ))
  write_health_state "connecting" "$health_failures" 0 "stream_starting"
  coproc ssh "${ssh_options[@]}" "$SSH_TARGET" "$(remote_action_command stream)"
  ssh_pid=$!
  log_health_event "info" "stream_started" "connecting" "$health_failures" "stream_started"

  while kill -0 "$ssh_pid" 2>/dev/null; do
    while IFS= read -r -t 0.01 -p protocol_line; do
      protocol_line="${protocol_line%$'\r'}"
      receive_protocol_line "$protocol_line"
    done

    if (( SECONDS - last_protocol_tick > protocol_timeout )); then
      (( health_failures += 1 ))
      log_health_event "error" "protocol_timeout" "degraded" "$health_failures" "stream_ping_timeout"
      write_health_state "degraded" "$health_failures" 0 "stream_ping_timeout"
      kill "$ssh_pid" 2>/dev/null || true
      break
    fi

    if (( SECONDS >= next_health_tick )); then
      if windows_health_check; then
        if (( health_failures > 0 || session_healthy == 0 )); then
          log_health_event "info" "health_recovered" "healthy" 0 "protocol_and_agent_healthy"
        fi
        health_failures=0
        reconnect_failures=0
        recovery_interval="$recovery_base_interval"
        next_recovery_tick=0
        session_healthy=1
        write_health_state "healthy" 0 0 "protocol_and_agent_healthy"
      else
        (( health_failures += 1 ))
        state="degraded"
        (( health_failures >= health_failure_threshold )) && state="failed"
        log_health_event "error" "health_failed" "$state" "$health_failures" "windows_agent_unhealthy"
        write_health_state "$state" "$health_failures" 0 "windows_agent_unhealthy"
        if (( health_failures >= health_failure_threshold )); then
          if (( SECONDS >= next_recovery_tick )); then
            if request_windows_recovery; then
              log_health_event "info" "windows_recovery_requested" "recovering" \
                "$health_failures" "recovery_task_requested"
              write_health_state "recovering" "$health_failures" \
                "$recovery_interval" "recovery_task_requested"
            else
              log_health_event "error" "windows_recovery_failed" "failed" \
                "$health_failures" "recovery_task_unavailable"
              write_health_state "failed" "$health_failures" \
                "$recovery_interval" "recovery_task_unavailable"
            fi
            next_recovery_tick=$(( SECONDS + recovery_interval ))
            recovery_interval=$(( recovery_interval * 2 ))
            (( recovery_interval > recovery_max_interval )) &&
              recovery_interval="$recovery_max_interval"
          fi
          kill "$ssh_pid" 2>/dev/null || true
          break
        fi
      fi
      next_health_tick=$(( SECONDS + health_interval ))
    fi

    process_file_completions

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

    if [[ -n "$file_offer_id" && "$file_offer_announced" == "0" ]]; then
      if (( file_offer_retry_ticks <= 0 )); then
        send_file_offer || true
        file_offer_retry_ticks=5
      else
        (( file_offer_retry_ticks -= 1 ))
      fi
    fi
    if [[ "$remote_file_drop_pending" == "1" && -z "$file_offer_id" ]]; then
      if (( remote_file_drop_retry_ticks <= 0 )); then
        retry_remote_file_drop || true
        remote_file_drop_retry_ticks=5
      else
        (( remote_file_drop_retry_ticks -= 1 ))
      fi
    fi

    sleep "${CLIPBOARD_CHECK_INTERVAL:-0.2}"
  done

  wait "$ssh_pid" 2>/dev/null || true
  if (( session_healthy == 0 )); then
    (( reconnect_failures += 1 ))
  fi
  reconnect_delay="${RECONNECT_INTERVAL:-1}"
  if (( reconnect_failures > 1 )); then
    reconnect_exponent=$(( reconnect_failures - 1 ))
    (( reconnect_exponent > 8 )) && reconnect_exponent=8
    reconnect_delay=$(( reconnect_delay * (2 ** reconnect_exponent) ))
  fi
  (( reconnect_delay > reconnect_max_interval )) &&
    reconnect_delay="$reconnect_max_interval"
  visible_failures="$health_failures"
  (( reconnect_failures > visible_failures )) &&
    visible_failures="$reconnect_failures"
  state="connecting"
  (( visible_failures >= health_failure_threshold )) && state="failed"
  log_health_event "info" "stream_reconnect_wait" "$state" \
    "$visible_failures" "stream_reconnect_backoff"
  write_health_state "$state" "$visible_failures" \
    "$reconnect_delay" "stream_reconnect_backoff"
  sleep "$reconnect_delay"
done
