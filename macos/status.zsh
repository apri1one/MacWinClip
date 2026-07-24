#!/bin/zsh
set -u

label="gui/$(id -u)/com.mac-windows-ssh-clipboard.agent"
if launchctl print "$label" >/dev/null 2>&1; then
  print -- "running=yes"
else
  print -- "running=no"
fi

config="$HOME/.config/mac-windows-ssh-clipboard/config.zsh"
if [[ -f "$config" ]]; then
  source "$config"
  print -- "ssh_target_configured=yes"
  health_command="powershell -NoProfile -ExecutionPolicy Bypass -File \"$WINDOWS_REMOTE_SCRIPT\" health"
  health="$(ssh -T -o BatchMode=yes -o ConnectTimeout=5 -o ClearAllForwardings=yes "$SSH_TARGET" "$health_command" 2>/dev/null)"
  health="${health%$'\r'}"
  if [[ "$health" =~ '^OK V3 [1-9][0-9]*$' ]]; then
    print -- "windows_reachable=yes"
  else
    print -- "windows_reachable=no"
  fi
else
  print -- "ssh_target_configured=no"
fi
