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

for command_name in ssh pbcopy pbpaste shasum base64; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    print -u2 -- "Missing command: $command_name"
    exit 1
  fi
done

remote_root="$(ssh -T -o BatchMode=yes -o ConnectTimeout=8 -o ClearAllForwardings=yes \
  "$ssh_target" 'powershell -NoProfile -Command "[Console]::Out.Write($env:LOCALAPPDATA)"')"
if [[ -z "$remote_root" ]]; then
  print -u2 -- "Could not discover Windows LOCALAPPDATA."
  exit 1
fi
remote_script="${remote_root}\\MacWindowsSSHClipboard\\remote.ps1"
health_command="powershell -NoProfile -ExecutionPolicy Bypass -File \"$remote_script\" health"
health="$(ssh -T -o BatchMode=yes -o ConnectTimeout=8 -o ClearAllForwardings=yes "$ssh_target" "$health_command")"
if [[ "$health" != "OK" ]]; then
  print -u2 -- "Windows bridge health check failed. Run windows/install.ps1 on Windows first."
  exit 1
fi

mkdir -p "$app_dir" "$config_dir" "$launch_agents"
mkdir -p "$HOME/.ssh"
chmod 700 "$app_dir" "$config_dir"
chmod 700 "$HOME/.ssh"
cp "$source_dir/bridge.zsh" "$app_dir/bridge.zsh"
cp "$source_dir/status.zsh" "$app_dir/status.zsh"
cp "$source_dir/uninstall.zsh" "$app_dir/uninstall.zsh"
chmod 700 "$app_dir/bridge.zsh" "$app_dir/status.zsh" "$app_dir/uninstall.zsh"

{
  printf 'SSH_TARGET=%q\n' "$ssh_target"
  printf 'WINDOWS_REMOTE_SCRIPT=%q\n' "$remote_script"
  printf 'CLIPBOARD_CHECK_INTERVAL=%q\n' "0.2"
  printf 'RECONNECT_INTERVAL=%q\n' "1"
} > "$config_dir/config.zsh"
chmod 600 "$config_dir/config.zsh"

if [[ "$auto_start" == "yes" ]]; then
  cp "$source_dir/com.mac-windows-ssh-clipboard.agent.plist" "$plist"
  chmod 600 "$plist"
  plutil -lint "$plist" >/dev/null

  launchctl bootout "gui/$(id -u)/com.mac-windows-ssh-clipboard.agent" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  launchctl kickstart "gui/$(id -u)/com.mac-windows-ssh-clipboard.agent"
  print -- "Installed. The bridge is running and will start automatically after macOS sign-in."
else
  launchctl bootout "gui/$(id -u)/com.mac-windows-ssh-clipboard.agent" 2>/dev/null || true
  rm -f "$plist"
  print -- "Installed without automatic start."
  print -- "Run manually: zsh $app_dir/bridge.zsh"
fi
