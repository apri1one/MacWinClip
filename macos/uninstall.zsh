#!/bin/zsh
set -eu
setopt null_glob

label="gui/$(id -u)/com.mac-windows-ssh-clipboard.agent"
launchctl bootout "$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.mac-windows-ssh-clipboard.agent.plist"
rm -rf "$HOME/.local/share/mac-windows-ssh-clipboard"
rm -rf "$HOME/.config/mac-windows-ssh-clipboard"
print -- "macOS clipboard bridge removed."
