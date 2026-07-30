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
  health="$(/usr/bin/perl -e \
    'my $timeout = shift @ARGV; alarm $timeout; exec @ARGV' \
    8 ssh -T -o BatchMode=yes -o ConnectTimeout=5 \
    -o ServerAliveInterval=3 -o ServerAliveCountMax=1 \
    -o ClearAllForwardings=yes "$SSH_TARGET" "$health_command" 2>/dev/null)"
  health="${health%$'\r'}"
  if [[ "$health" =~ '^OK V[0-9]+ [1-9][0-9]*$' ]]; then
    print -- "windows_reachable=yes"
  else
    print -- "windows_reachable=no"
  fi
else
  print -- "ssh_target_configured=no"
fi

health_state="$HOME/Library/Caches/mac-windows-ssh-clipboard/health.json"
if [[ -f "$health_state" ]] &&
   plutil -extract state raw -o - "$health_state" >/dev/null 2>&1; then
  for key in state failures nextRetrySeconds updatedUtc detail; do
    value="$(plutil -extract "$key" raw -o - "$health_state" 2>/dev/null)" || value=""
    print -- "self_heal_${key}=$value"
  done
else
  print -- "self_heal_state=unknown"
fi
