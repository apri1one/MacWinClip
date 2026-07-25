# MacWinClip agent rules

This repository installs a text, image, and regular-file clipboard bridge
between one macOS GUI session and the matching Windows GUI user.

## Invariants

- Detect the current OS before running commands.
- Mac is the only SSH client; Windows runs OpenSSH Server.
- Keep one persistent Windows→Mac stdout stream. Mac→Windows payloads use SCP
  plus a short SSH commit; Windows→Mac acknowledgements use a short SSH action.
- Do not depend on Windows OpenSSH forwarding stdin to a nested PowerShell
  process.
- Never let the Windows SSH/Session 0 process access the desktop clipboard.
- Only `windows/agent.ps1` in a nonzero desktop SessionId may use
  `Get-Clipboard` or `Set-Clipboard`.
- macOS clipboard access must stay in the current user's Aqua LaunchAgent.
- Support `TEXT`, `PNG`, and `FILES`. `FILES` carries only a small JSON
  manifest in the stdout protocol; file bytes always use SCP.
- Mac→Windows regular files use a lazy offer: copy sends only names and sizes,
  Windows places virtual files on the clipboard, and a content request emits
  `FETCH` before the Mac stages or uploads bytes. Do not replace this with
  global keyboard hooks or synthetic paste input.
- Windows→Mac regular files are still eager in this Beta: copying on Windows
  stages and transfers them before Finder paste.
- Limit UTF-8 text to 1 MiB and normalized PNG data to 16 MiB.
- Limit one file selection to 1000 regular files and 10 GiB total. Reject
  directories, symbolic links, unsafe names, duplicate names, and manifests
  over 1 MiB.
- Keep file copying in separate workers so text and screenshots remain
  responsive. Show native WinForms and AppKit progress windows on both ends.
- Stage outbound files in the current user's private runtime cache before SCP.
  This avoids protected-folder read failures in `/usr/bin/scp` and prevents a
  changing source file from silently changing during transfer.
- A received macOS file clipboard needs a small pasteboard owner process.
  Keep it only until the clipboard changes, and stop it with the bridge.
- Always use copy semantics. Received files remain in `Downloads/MacWinClip`
  because a file clipboard contains local paths, not file bytes.
- Do not use AppleScript, `osascript`, Terminal control, Accessibility or UI
  automation.

## Installation

1. Tell the user that both Windows and Mac components must be installed.
2. Before installing, ask whether to enable automatic start after each GUI
   user signs in. This is not pre-login system boot.
   - enabled: use the default installers;
   - disabled: use Windows `-NoAutoStart` and macOS `--no-autostart`.
3. Follow `docs/NEW-COMPUTER-SETUP.zh-CN.md`.
4. Verify the Windows host key and:

   ```zsh
   ssh -o BatchMode=yes <target> "whoami"
   ```

5. Run `windows/install.ps1` as the logged-in Windows desktop user.
6. Require `Running=True` and `SessionId != 0`.
7. Require `xcrun --find swiftc` on the Mac.
8. Run `macos/install.zsh <target>` locally on the Mac.
9. Verify `macos/status.zsh`.

The SSH user and Windows desktop Agent user must be the same account. Codex
Cloud must not claim it can reach a private LAN unless an explicit runner or
route has been verified.

## Safety and acceptance

- Never read, print, log or upload pre-existing clipboard contents.
- Never request or expose private keys, passwords or tokens.
- Preserve existing SSH configuration and host-key checking.
- Do not expose TCP 22 to the public Internet.
- Use generated, non-sensitive text, images, and small regular files to test
  each direction separately.
- For Mac→Windows acceptance, verify that Finder copy alone sends no file bytes
  and opens no progress window; Windows paste must trigger `FETCH` and both
  progress windows.
- Verify no echo loop, queues eventually return to zero, and one persistent
  `stream` SSH process carries Windows→Mac traffic without network polling.
- Do not add directories, symbolic links, rich text, history, iPhone or cloud
  features unless scope is explicitly expanded.
- All changes must remain reversible with the included uninstall scripts.

Before release, run `tests/validate-windows.ps1` and
`tests/validate-macos.zsh`. These do not replace a real two-GUI-session
clipboard acceptance test.
