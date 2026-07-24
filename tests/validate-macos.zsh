#!/bin/zsh
set -eu

project_root="${0:A:h:h}"

for script in "$project_root"/macos/*.zsh; do
  /bin/zsh -n "$script"
done

/usr/bin/plutil -lint "$project_root/macos/com.mac-windows-ssh-clipboard.agent.plist" >/dev/null

coproc /bin/cat
worker_pid=$!
print -r -p -- "controlled-coproc-probe"
if ! IFS= read -r -t 1 -p response || [[ "$response" != "controlled-coproc-probe" ]]; then
  kill "$worker_pid" 2>/dev/null || true
  print -u2 -- "Persistent coprocess stdin/stdout validation failed."
  exit 1
fi
kill "$worker_pid" 2>/dev/null || true
wait "$worker_pid" 2>/dev/null || true

print -- "PASS macOS zsh, plist, and persistent coprocess validation"
