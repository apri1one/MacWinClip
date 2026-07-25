#!/bin/zsh
set -u
setopt pipe_fail
setopt extended_glob
umask 077

if (( $# != 3 )); then
  print -u2 -- "Usage: file-transfer.zsh <send|receive> <message-id> <manifest>"
  exit 2
fi

mode="$1"
message_id="$2"
manifest_path="$3"
if [[ "$mode" != "send" && "$mode" != "receive" ]]; then
  exit 2
fi
if [[ ${#message_id} -ne 32 || "$message_id" != [a-f0-9]## ]]; then
  exit 2
fi

config="$HOME/.config/mac-windows-ssh-clipboard/config.zsh"
if [[ ! -f "$config" ]]; then
  exit 1
fi
source "$config"

manifest_message_id="$("$CLIPBOARD_HELPER" manifest-id "$manifest_path" 2>/dev/null)" || exit 1
if [[ "$manifest_message_id" != "$message_id" ]]; then
  exit 1
fi

runtime_dir="$HOME/Library/Caches/mac-windows-ssh-clipboard"
transfer_dir="$runtime_dir/transfers"
completion_dir="$runtime_dir/completed"
state_file="$transfer_dir/$message_id.state.json"
cancel_file="$transfer_dir/$message_id.cancel"
public_manifest="$transfer_dir/$message_id.public.json"
worker_pid_file="$transfer_dir/$message_id.worker.pid"
owner_pid_file="$transfer_dir/$message_id.owner.pid"
owner_count_file="$transfer_dir/$message_id.owner.count"
staging_root="$transfer_dir/$message_id.staging"
receive_destination=""
mkdir -p "$transfer_dir" "$completion_dir"
chmod 700 "$runtime_dir" "$transfer_dir" "$completion_dir"
rm -f "$cancel_file"
print -r -- "$$" > "$worker_pid_file"
trap 'rm -f "$worker_pid_file"' EXIT

ssh_options=(
  -T
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o ClearAllForwardings=yes
)
scp_options=(
  -q
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o ClearAllForwardings=yes
)

remote_action_command() {
  local action="$1"
  shift
  print -r -- "powershell -NoProfile -ExecutionPolicy Bypass -File \"$WINDOWS_REMOTE_SCRIPT\" $action $*"
}

remote_action() {
  ssh "${ssh_options[@]}" "$SSH_TARGET" "$(remote_action_command "$@")" 2>/dev/null
}

write_progress() {
  "$CLIPBOARD_HELPER" progress-write \
    "$state_file" "$1" "$2" "$3" "$4" "$5" "$6" 2>/dev/null
}

start_progress_ui() {
  "$PROGRESS_UI" "$state_file" "$cancel_file" >/dev/null 2>&1 &!
}

cancel_requested() {
  [[ -f "$cancel_file" ]]
}

remove_receive_destination() {
  if [[ -n "$receive_destination" &&
        "$receive_destination" == "$HOME/Downloads/MacWinClip/$message_id" &&
        -d "$receive_destination" ]]; then
    rm -rf "$receive_destination"
  fi
}

decode_base64() {
  print -rn -- "$1" | base64 -D
}

schedule_state_cleanup() {
  (
    sleep 60
    rm -f "$state_file" "$cancel_file"
  ) &!
}

load_manifest_plan() {
  local line index name64 size hash source64
  plan_indexes=()
  plan_names=()
  plan_sizes=()
  plan_hashes=()
  plan_sources=()

  while IFS=$'\t' read -r index name64 size hash source64; do
    [[ -z "$index" ]] && continue
    plan_indexes+=("$index")
    plan_names+=("$(decode_base64 "$name64")")
    plan_sizes+=("$size")
    plan_hashes+=("$hash")
    if [[ "$source64" == "-" ]]; then
      plan_sources+=("")
    else
      plan_sources+=("$(decode_base64 "$source64")")
    fi
  done < <("$CLIPBOARD_HELPER" manifest-plan "$1")

  (( ${#plan_indexes} > 0 )) || return 1
  return 0
}

display_name_for_plan() {
  if (( ${#plan_names} == 1 )); then
    print -r -- "$plan_names[1]"
  else
    print -r -- "${#plan_names} 个文件"
  fi
}

cancel_transfer() {
  remote_action cancel-files "$message_id" >/dev/null 2>&1 || true
  remove_receive_destination
  write_progress "Canceled" 0 "$1" "$2" "传输已取消。" "$3" || true
  rm -f "$manifest_path" "$public_manifest"
  rm -rf "$staging_root"
  schedule_state_cleanup
  exit 0
}

fail_transfer() {
  remote_action fail-files "$message_id" >/dev/null 2>&1 || true
  remove_receive_destination
  write_progress "Error" 0 "$1" "$2" "$3" "$4" || true
  print -r -- "failed" > "$completion_dir/$message_id.failed"
  rm -f "$manifest_path" "$public_manifest"
  rm -rf "$staging_root"
  schedule_state_cleanup
  exit 1
}

send_to_windows() {
  local total display_name response transferred source_path remote_part
  local scp_pid remote_size current index array_index file_size

  total="$("$CLIPBOARD_HELPER" manifest-total "$manifest_path")" || return 1
  load_manifest_plan "$manifest_path" || return 1
  display_name="$(display_name_for_plan)"
  write_progress "Preparing" 0 "$total" "$display_name" "正在计算 SHA-256…" "正在发送到 Windows" || return 1
  start_progress_ui

  rm -rf "$staging_root"
  "$CLIPBOARD_HELPER" stage-manifest \
    "$manifest_path" "$public_manifest" "$staging_root" "$cancel_file" || {
    fail_transfer "$total" "$display_name" "无法准备文件清单。" "正在发送到 Windows"
  }
  load_manifest_plan "$public_manifest" || {
    fail_transfer "$total" "$display_name" "无法读取文件清单。" "正在发送到 Windows"
  }
  cancel_requested && cancel_transfer "$total" "$display_name" "正在发送到 Windows"

  scp "${scp_options[@]}" \
    "$public_manifest" \
    "$SSH_TARGET:$WINDOWS_SCP_ROOT/upload.$message_id.files.tmp" || {
      fail_transfer "$total" "$display_name" "无法上传文件清单。" "正在发送到 Windows"
    }
  response="$(remote_action begin-files "$message_id")" || {
    fail_transfer "$total" "$display_name" "Windows 拒绝了文件清单。" "正在发送到 Windows"
  }
  response="${response%$'\r'}"
  [[ "$response" == "READY $message_id" ]] || {
    fail_transfer "$total" "$display_name" "Windows 文件接收器未就绪。" "正在发送到 Windows"
  }

  transferred=0
  for (( array_index = 1; array_index <= ${#plan_indexes}; array_index++ )); do
    index="$plan_indexes[$array_index]"
    source_path="$staging_root/$(printf '%06d' "$index").payload"
    file_size="$plan_sizes[$array_index]"
    [[ -n "$source_path" && -f "$source_path" ]] || {
      fail_transfer "$total" "$display_name" "源文件已不存在。" "正在发送到 Windows"
    }
    remote_part="$WINDOWS_SCP_ROOT/incoming/$message_id/$(printf '%06d' "$index").part"
    scp "${scp_options[@]}" "$source_path" "$SSH_TARGET:$remote_part" &
    scp_pid=$!

    while kill -0 "$scp_pid" 2>/dev/null; do
      if cancel_requested; then
        kill "$scp_pid" 2>/dev/null || true
        wait "$scp_pid" 2>/dev/null || true
        cancel_transfer "$total" "$display_name" "正在发送到 Windows"
      fi
      remote_size="$(remote_action file-size "$message_id" "$index" "$transferred" 2>/dev/null || print 0)"
      remote_size="${remote_size%$'\r'}"
      if [[ "$remote_size" == "CANCEL" ]]; then
        print -r -- "cancel" > "$cancel_file"
        continue
      fi
      [[ "$remote_size" == <-> ]] || remote_size=0
      current=$(( transferred + remote_size ))
      (( current > total )) && current="$total"
      write_progress "Transferring" "$current" "$total" "$display_name" "正在传输文件…" "正在发送到 Windows" || true
      sleep 0.5
    done
    if ! wait "$scp_pid"; then
      fail_transfer "$total" "$display_name" "SCP 文件上传失败。" "正在发送到 Windows"
    fi
    transferred=$(( transferred + file_size ))
    write_progress "Transferring" "$transferred" "$total" "$display_name" "正在传输文件…" "正在发送到 Windows" || true
  done

  write_progress "Verifying" "$total" "$total" "$display_name" "Windows 正在校验 SHA-256…" "正在发送到 Windows" || true
  response="$(remote_action commit-files "$message_id")" || {
    fail_transfer "$total" "$display_name" "Windows 文件校验或提交失败。" "正在发送到 Windows"
  }
  response="${response%$'\r'}"
  [[ "$response" == "ACK $message_id" ]] || {
    fail_transfer "$total" "$display_name" "Windows 未确认文件提交。" "正在发送到 Windows"
  }
  write_progress "Done" "$total" "$total" "$display_name" "传输完成。" "正在发送到 Windows" || true
  rm -f "$manifest_path" "$public_manifest"
  rm -rf "$staging_root"
  schedule_state_cleanup
}

receive_from_windows() {
  local total display_name destination transferred file_size index array_index
  local local_part final_path remote_payload scp_pid current change_count response
  local owner_pid owner_attempt
  local last_remote_update now_epoch previous_epoch

  total="$("$CLIPBOARD_HELPER" manifest-total "$manifest_path")" || return 1
  load_manifest_plan "$manifest_path" || return 1
  display_name="$(display_name_for_plan)"
  destination="$HOME/Downloads/MacWinClip/$message_id"
  receive_destination="$destination"
  mkdir -p "$destination"
  chmod 700 "$HOME/Downloads/MacWinClip" "$destination" 2>/dev/null || true
  write_progress "Transferring" 0 "$total" "$display_name" "正在从 Windows 接收…" "正在从 Windows 接收" || return 1
  start_progress_ui

  transferred=0
  previous_epoch=0
  for (( array_index = 1; array_index <= ${#plan_indexes}; array_index++ )); do
    index="$plan_indexes[$array_index]"
    file_size="$plan_sizes[$array_index]"
    local_part="$destination/.$(printf '%06d' "$index").part"
    final_path="$destination/$plan_names[$array_index]"
    remote_payload="$WINDOWS_SCP_ROOT/outgoing/$message_id/$(printf '%06d' "$index").payload"
    scp "${scp_options[@]}" "$SSH_TARGET:$remote_payload" "$local_part" &
    scp_pid=$!

    while kill -0 "$scp_pid" 2>/dev/null; do
      if cancel_requested; then
        kill "$scp_pid" 2>/dev/null || true
        wait "$scp_pid" 2>/dev/null || true
        cancel_transfer "$total" "$display_name" "正在从 Windows 接收"
      fi
      if [[ -f "$local_part" ]]; then
        current=$(( transferred + $(wc -c < "$local_part" | tr -d ' ') ))
      else
        current="$transferred"
      fi
      (( current > total )) && current="$total"
      write_progress "Transferring" "$current" "$total" "$display_name" "正在接收文件…" "正在从 Windows 接收" || true
      now_epoch="$(date +%s)"
      if (( now_epoch != previous_epoch )); then
        remote_action progress "$message_id" "$current" Transferring >/dev/null 2>&1 || true
        previous_epoch="$now_epoch"
      fi
      sleep 0.5
    done
    if ! wait "$scp_pid"; then
      fail_transfer "$total" "$display_name" "SCP 文件下载失败。" "正在从 Windows 接收"
    fi
    if [[ "$(wc -c < "$local_part" | tr -d ' ')" != "$file_size" ]]; then
      fail_transfer "$total" "$display_name" "接收文件大小不匹配。" "正在从 Windows 接收"
    fi
    write_progress "Verifying" "$transferred" "$total" "$display_name" "正在校验 SHA-256…" "正在从 Windows 接收" || true
    "$CLIPBOARD_HELPER" verify-file "$local_part" "$plan_hashes[$array_index]" || {
      fail_transfer "$total" "$display_name" "SHA-256 校验失败。" "正在从 Windows 接收"
    }
    mv -f "$local_part" "$final_path"
    transferred=$(( transferred + file_size ))
  done

  rm -f "$owner_count_file" "$owner_pid_file"
  "$CLIPBOARD_HELPER" own-files \
    "$manifest_path" "$destination" "$owner_pid_file" \
    > "$owner_count_file" 2>/dev/null &!
  owner_pid=$!
  print -r -- "$owner_pid" > "$owner_pid_file"
  for owner_attempt in {1..40}; do
    [[ -s "$owner_count_file" ]] && break
    if ! kill -0 "$owner_pid" 2>/dev/null; then
      break
    fi
    sleep 0.05
  done
  change_count="$(head -n 1 "$owner_count_file" 2>/dev/null)" || change_count=""
  rm -f "$owner_count_file"
  if [[ "$change_count" != <-> ]]; then
    kill "$owner_pid" 2>/dev/null || true
    rm -f "$owner_pid_file"
    fail_transfer "$total" "$display_name" "无法写入 Mac 文件剪贴板。" "正在从 Windows 接收"
  fi
  remote_action progress "$message_id" "$total" Done >/dev/null 2>&1 || true
  response="$(remote_action ack "$message_id")" || true
  response="${response%$'\r'}"
  [[ "$response" == "ACK $message_id" ]] || true
  print -r -- "$change_count" > "$completion_dir/$message_id.count"
  write_progress "Done" "$total" "$total" "$display_name" "传输完成。" "正在从 Windows 接收" || true
  rm -f "$manifest_path"
  schedule_state_cleanup
}

if [[ "$mode" == "send" ]]; then
  send_to_windows
else
  receive_from_windows
fi
