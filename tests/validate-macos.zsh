#!/bin/zsh
set -eu

project_root="${0:A:h:h}"
test_root="$(mktemp -d /tmp/macwinclip-validation.XXXXXX)"

cleanup() {
  if [[ "$test_root" == /tmp/macwinclip-validation.* && -d "$test_root" ]]; then
    rm -rf "$test_root"
  fi
}
trap cleanup EXIT

for script in "$project_root"/macos/*.zsh; do
  /bin/zsh -n "$script"
done

/usr/bin/plutil -lint "$project_root/macos/com.mac-windows-ssh-clipboard.agent.plist" >/dev/null

if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
  print -u2 -- "Swift compiler is unavailable. Install Apple Command Line Tools."
  exit 1
fi

/usr/bin/xcrun swiftc -O "$project_root/macos/clipboard-helper.swift" \
  -framework AppKit \
  -o "$test_root/clipboard-helper"
[[ -x "$test_root/clipboard-helper" ]]

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

print -- "PASS macOS zsh, plist, Swift helper build, and persistent coprocess validation"
