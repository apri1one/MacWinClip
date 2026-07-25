#!/bin/zsh
set -eu

if [[ "$(uname -s)" != "Darwin" ]]; then
  print -u2 -- "Run this installer on macOS."
  exit 1
fi

auto_start="yes"
if (( $# > 0 )) && [[ "$1" == "--no-autostart" ]]; then
  auto_start="no"
  shift
fi

if (( $# != 1 )); then
  print -u2 -- "Usage: ./macos/install.zsh [--no-autostart] <windows-user@windows-host-or-ssh-alias>"
  exit 1
fi

ssh_target="$1"
if [[ ! "$ssh_target" =~ '^[A-Za-z0-9._@:-]+$' ]]; then
  print -u2 -- "Unsafe SSH target. Use an SSH alias, hostname, IPv4 address, or user@host."
  exit 1
fi

source_dir="${0:A:h}"
app_dir="$HOME/.local/share/mac-windows-ssh-clipboard"
config_dir="$HOME/.config/mac-windows-ssh-clipboard"
launch_agents="$HOME/Library/LaunchAgents"
plist="$launch_agents/com.mac-windows-ssh-clipboard.agent.plist"
launch_domain="gui/$(id -u)"
launch_target="$launch_domain/com.mac-windows-ssh-clipboard.agent"

stop_existing_agent() {
  local attempt

  launchctl bootout "$launch_target" 2>/dev/null || true
  if launchctl print "$launch_target" >/dev/null 2>&1; then
    launchctl bootout "$launch_domain" "$plist" 2>/dev/null || true
  fi

  for attempt in {1..20}; do
    if ! launchctl print "$launch_target" >/dev/null 2>&1; then
      sleep 0.2
      return 0
    fi
    sleep 0.1
  done

  print -u2 -- "Could not stop the existing macOS LaunchAgent."
  return 1
}

for command_name in ssh scp base64 uuidgen xcrun; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    print -u2 -- "Missing command: $command_name"
    exit 1
  fi
done
if ! xcrun --find swiftc >/dev/null 2>&1; then
  print -u2 -- "Missing Swift compiler. Install Apple Command Line Tools first: xcode-select --install"
  exit 1
fi

localappdata_command="powershell -NoProfile -NonInteractive -EncodedCommand WwBDAG8AbgBzAG8AbABlAF0AOgA6AE8AdQB0AC4AVwByAGkAdABlACgAJABlAG4AdgA6AEwATwBDAEEATABBAFAAUABEAEEAVABBACkA"
remote_root="$(ssh -T -o BatchMode=yes -o ConnectTimeout=8 -o ClearAllForwardings=yes \
  "$ssh_target" "$localappdata_command")"
if [[ -z "$remote_root" ]]; then
  print -u2 -- "Could not discover Windows LOCALAPPDATA."
  exit 1
fi
remote_install_root="${remote_root}\\MacWindowsSSHClipboard"
remote_script="${remote_install_root}\\remote.ps1"
remote_scp_root="${remote_install_root//\\//}"
health_command="powershell -NoProfile -ExecutionPolicy Bypass -File \"$remote_script\" health"
health="$(ssh -T -o BatchMode=yes -o ConnectTimeout=8 -o ClearAllForwardings=yes "$ssh_target" "$health_command")"
health="${health%$'\r'}"
if [[ ! "$health" =~ '^OK V5 [1-9][0-9]*$' ]]; then
  print -u2 -- "Windows bridge health check failed. Run windows/install.ps1 on Windows first."
  exit 1
fi

mkdir -p "$app_dir" "$config_dir" "$launch_agents"
mkdir -p "$HOME/.ssh"
chmod 700 "$app_dir" "$config_dir"
chmod 700 "$HOME/.ssh"
cp "$source_dir/bridge.zsh" "$app_dir/bridge.zsh"
cp "$source_dir/file-transfer.zsh" "$app_dir/file-transfer.zsh"
cp "$source_dir/status.zsh" "$app_dir/status.zsh"
cp "$source_dir/uninstall.zsh" "$app_dir/uninstall.zsh"
chmod 700 "$app_dir/bridge.zsh" "$app_dir/file-transfer.zsh" "$app_dir/status.zsh" "$app_dir/uninstall.zsh"
xcrun swiftc -O "$source_dir/clipboard-helper.swift" -framework AppKit \
  -o "$app_dir/clipboard-helper.new"
mv -f "$app_dir/clipboard-helper.new" "$app_dir/clipboard-helper"
chmod 700 "$app_dir/clipboard-helper"
xcrun swiftc -O "$source_dir/progress-ui.swift" -framework AppKit \
  -o "$app_dir/progress-ui.new"
mv -f "$app_dir/progress-ui.new" "$app_dir/progress-ui"
chmod 700 "$app_dir/progress-ui"

{
  printf 'SSH_TARGET=%q\n' "$ssh_target"
  printf 'WINDOWS_REMOTE_SCRIPT=%q\n' "$remote_script"
  printf 'WINDOWS_SCP_ROOT=%q\n' "$remote_scp_root"
  printf 'CLIPBOARD_HELPER=%q\n' "$app_dir/clipboard-helper"
  printf 'FILE_TRANSFER_SCRIPT=%q\n' "$app_dir/file-transfer.zsh"
  printf 'PROGRESS_UI=%q\n' "$app_dir/progress-ui"
  printf 'CLIPBOARD_CHECK_INTERVAL=%q\n' "0.2"
  printf 'RECONNECT_INTERVAL=%q\n' "1"
  printf 'MAX_TEXT_BYTES=%q\n' "1048576"
  printf 'MAX_IMAGE_BYTES=%q\n' "16777216"
  printf 'MAX_MANIFEST_BYTES=%q\n' "1048576"
  printf 'MAX_FILE_BYTES=%q\n' "10737418240"
} > "$config_dir/config.zsh"
chmod 600 "$config_dir/config.zsh"

if [[ "$auto_start" == "yes" ]]; then
  cp "$source_dir/com.mac-windows-ssh-clipboard.agent.plist" "$plist"
  chmod 600 "$plist"
  plutil -lint "$plist" >/dev/null

  stop_existing_agent
  if ! launchctl bootstrap "$launch_domain" "$plist"; then
    sleep 0.5
    launchctl bootstrap "$launch_domain" "$plist"
  fi
  launchctl kickstart "$launch_target"
  print -- "Installed. The bridge is running and will start automatically after macOS sign-in."
else
  stop_existing_agent
  rm -f "$plist"
  print -- "Installed without automatic start."
  print -- "Run manually: zsh $app_dir/bridge.zsh"
fi
