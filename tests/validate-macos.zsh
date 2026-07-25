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
/usr/bin/xcrun swiftc -O "$project_root/tests/generate-video-fixtures.swift" \
  -framework AVFoundation \
  -framework CoreVideo \
  -o "$test_root/generate-video-fixtures"
"$test_root/generate-video-fixtures" "$test_root/video-cache"
mov_a_size="$(wc -c < "$test_root/video-cache/generated-a.mov" | tr -d ' ')"
mov_b_size="$(wc -c < "$test_root/video-cache/generated-b.mov" | tr -d ' ')"
mp4_size="$(wc -c < "$test_root/video-cache/generated-c.mp4" | tr -d ' ')"
video_total=$(( mov_a_size + mov_b_size + mp4_size ))
printf '%s\n' \
  "{\"version\":2,\"id\":\"22222222222222222222222222222222\",\"totalBytes\":$video_total,\"files\":[{\"index\":0,\"name\":\"generated-a.mov\",\"kind\":\"file\",\"size\":$mov_a_size,\"sha256\":\"\"},{\"index\":1,\"name\":\"generated-b.mov\",\"kind\":\"file\",\"size\":$mov_b_size,\"sha256\":\"\"},{\"index\":2,\"name\":\"generated-c.mp4\",\"kind\":\"file\",\"size\":$mp4_size,\"sha256\":\"\"}]}" \
  > "$test_root/video-offer.json"
promise_result="$("$test_root/clipboard-helper" validate-promise-layout \
  "$test_root/video-offer.json" \
  "$test_root/video-cache" \
  "$test_root/video-promise-work" 2>/dev/null)"
[[ "$promise_result" == *"topLevel=3 fileURLs=3 promises=3 leadingFileURLs=3 urlChangeStable=true"* ]]

mkdir -p "$test_root/controlled.focusee/empty"
print -rn -- "MacWinClip controlled file payload" \
  > "$test_root/controlled.focusee/controlled.bin"
controlled_size="$(wc -c < "$test_root/controlled.focusee/controlled.bin" | tr -d ' ')"
"$test_root/clipboard-helper" file-manifest \
  "$test_root/private.json" \
  "$test_root/controlled.focusee" >/dev/null
"$test_root/clipboard-helper" set-id \
  "$test_root/private.json" \
  11111111111111111111111111111111
"$test_root/clipboard-helper" offer-manifest \
  "$test_root/private.json" \
  "$test_root/offer.json"
offer_plan="$("$test_root/clipboard-helper" manifest-plan "$test_root/offer.json" | grep $'\tfile\t')"
IFS=$'\t' read -r offer_index _ _ _ offer_hash offer_source <<< "$offer_plan"
[[ "$offer_hash" == "-" && "$offer_source" == "-" ]]
if grep -q 'sourcePath' "$test_root/offer.json"; then
  print -u2 -- "Lazy file offer leaked a source path."
  exit 1
fi
private_plan="$("$test_root/clipboard-helper" manifest-plan "$test_root/private.json" | grep $'\tfile\t')"
IFS=$'\t' read -r _ _ _ _ private_hash private_source <<< "$private_plan"
[[ "$private_hash" == "-" && "$private_source" != "-" ]]
[[ "$(print -rn -- "$private_source" | base64 -D)" == "${test_root:A}/controlled.focusee/controlled.bin" ]]
"$test_root/clipboard-helper" stage-manifest \
  "$test_root/private.json" \
  "$test_root/public.json" \
  "$test_root/staging" \
  "$test_root/cancel.request"
cmp -s \
  "$test_root/controlled.focusee/controlled.bin" \
  "$test_root/staging/$(printf '%06d' "$offer_index").payload"
[[ "$("$test_root/clipboard-helper" manifest-total "$test_root/public.json")" == "$controlled_size" ]]
plan="$("$test_root/clipboard-helper" manifest-plan "$test_root/public.json" | grep $'\tfile\t')"
[[ "$plan" == "$offer_index"$'\tfile\t'* ]]
IFS=$'\t' read -r _ _ _ _ hash _ <<< "$plan"
"$test_root/clipboard-helper" verify-file \
  "$test_root/controlled.focusee/controlled.bin" "$hash"
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
directory_lines="$("$test_root/clipboard-helper" manifest-plan "$test_root/public.json" | grep $'\tdirectory\t' | wc -l | tr -d ' ')"
[[ "$directory_lines" == 2 ]]

printf '%s\n' \
  '{"version":2,"id":"11111111111111111111111111111111","totalBytes":1,"files":[{"index":0,"name":"../escape.bin","kind":"file","size":1,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}]}' \
  > "$test_root/unsafe.json"
if "$test_root/clipboard-helper" manifest-total "$test_root/unsafe.json" >/dev/null 2>&1; then
  print -u2 -- "Unsafe relative path was accepted."
  exit 1
fi

ln -s "$test_root/controlled.focusee/controlled.bin" "$test_root/link.bin"
printf '%s\n' \
  "{\"version\":2,\"id\":\"11111111111111111111111111111111\",\"totalBytes\":$controlled_size,\"files\":[{\"index\":0,\"name\":\"link.bin\",\"kind\":\"file\",\"size\":$controlled_size,\"sha256\":\"\",\"sourcePath\":\"$test_root/link.bin\"}]}" \
  > "$test_root/symlink.json"
if "$test_root/clipboard-helper" stage-manifest \
  "$test_root/symlink.json" \
  "$test_root/symlink-public.json" \
  "$test_root/symlink-staging" \
  "$test_root/cancel.request" >/dev/null 2>&1; then
  print -u2 -- "Symbolic-link source was followed."
  exit 1
fi

printf '%s\n' \
  '{"version":2,"id":"11111111111111111111111111111111","totalBytes":0,"files":[{"index":0,"name":"empty.focusee","kind":"directory","size":0,"sha256":""}]}' \
  > "$test_root/empty-directory.json"
"$test_root/clipboard-helper" stage-manifest \
  "$test_root/empty-directory.json" \
  "$test_root/empty-directory-public.json" \
  "$test_root/empty-directory-staging" \
  "$test_root/cancel.request"
[[ -d "$test_root/empty-directory-staging" ]]
[[ -z "$(find "$test_root/empty-directory-staging" -type f -print -quit)" ]]

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

print -- "PASS macOS zsh, plist, Swift builds, multi-video promise layout, directory manifest/hash, and persistent coprocess validation"
