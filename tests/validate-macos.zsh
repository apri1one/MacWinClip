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

mkdir -p "$test_root/empty-home"
set +e
HOME="$test_root/empty-home" /bin/zsh "$project_root/macos/file-transfer.zsh" \
  send 11111111111111111111111111111111 "$test_root/missing.json" >/dev/null 2>&1
valid_id_status=$?
HOME="$test_root/empty-home" /bin/zsh "$project_root/macos/file-transfer.zsh" \
  send invalid "$test_root/missing.json" >/dev/null 2>&1
invalid_id_status=$?
set -e
[[ "$valid_id_status" == 1 ]]
[[ "$invalid_id_status" == 2 ]]

/usr/bin/plutil -lint "$project_root/macos/com.mac-windows-ssh-clipboard.agent.plist" >/dev/null

if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
  print -u2 -- "Swift compiler is unavailable. Install Apple Command Line Tools."
  exit 1
fi

/usr/bin/xcrun swiftc -O "$project_root/macos/clipboard-helper.swift" \
  -framework AppKit \
  -o "$test_root/clipboard-helper"
[[ -x "$test_root/clipboard-helper" ]]
/usr/bin/xcrun swiftc -O "$project_root/macos/progress-ui.swift" \
  -framework AppKit \
  -o "$test_root/progress-ui"
[[ -x "$test_root/progress-ui" ]]

print -rn -- "MacWinClip controlled file payload" > "$test_root/controlled.bin"
controlled_size="$(wc -c < "$test_root/controlled.bin" | tr -d ' ')"
printf '%s\n' \
  "{\"version\":1,\"id\":\"\",\"totalBytes\":$controlled_size,\"files\":[{\"index\":0,\"name\":\"controlled.bin\",\"size\":$controlled_size,\"sha256\":\"\",\"sourcePath\":\"$test_root/controlled.bin\"}]}" \
  > "$test_root/private.json"
"$test_root/clipboard-helper" set-id \
  "$test_root/private.json" \
  11111111111111111111111111111111
"$test_root/clipboard-helper" offer-manifest \
  "$test_root/private.json" \
  "$test_root/offer.json"
offer_plan="$("$test_root/clipboard-helper" manifest-plan "$test_root/offer.json")"
IFS=$'\t' read -r _ _ _ offer_hash offer_source <<< "$offer_plan"
[[ "$offer_hash" == "-" && "$offer_source" == "-" ]]
if grep -q 'sourcePath' "$test_root/offer.json"; then
  print -u2 -- "Lazy file offer leaked a source path."
  exit 1
fi
private_plan="$("$test_root/clipboard-helper" manifest-plan "$test_root/private.json")"
IFS=$'\t' read -r _ _ _ private_hash private_source <<< "$private_plan"
[[ "$private_hash" == "-" && "$private_source" != "-" ]]
[[ "$(print -rn -- "$private_source" | base64 -D)" == "$test_root/controlled.bin" ]]
"$test_root/clipboard-helper" stage-manifest \
  "$test_root/private.json" \
  "$test_root/public.json" \
  "$test_root/staging" \
  "$test_root/cancel.request"
cmp -s "$test_root/controlled.bin" "$test_root/staging/000000.payload"
[[ "$("$test_root/clipboard-helper" manifest-total "$test_root/public.json")" == "$controlled_size" ]]
plan="$("$test_root/clipboard-helper" manifest-plan "$test_root/public.json")"
[[ "$plan" == 0$'\t'* ]]
IFS=$'\t' read -r _ _ _ hash _ <<< "$plan"
"$test_root/clipboard-helper" verify-file "$test_root/controlled.bin" "$hash"
"$test_root/clipboard-helper" progress-write \
  "$test_root/progress.json" \
  Transferring \
  "$controlled_size" \
  "$controlled_size" \
  controlled.bin \
  controlled \
  send
[[ -s "$test_root/progress.json" ]]
if grep -q 'sourcePath' "$test_root/public.json"; then
  print -u2 -- "Public file manifest leaked a source path."
  exit 1
fi

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

print -- "PASS macOS zsh, plist, Swift builds, file manifest/hash, and persistent coprocess validation"
