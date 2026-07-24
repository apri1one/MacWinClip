# MacWinClip agent rules

This repository installs a text-and-image clipboard bridge between one macOS
GUI session and the matching Windows GUI user.

## Invariants

- Detect the current OS before running commands.
- Mac is the only SSH client; Windows runs OpenSSH Server.
- Keep one persistent SSH process: Mac→Windows uses stdin, Windows→Mac stdout.
- Never let the Windows SSH/Session 0 process access the desktop clipboard.
- Only `windows/agent.ps1` in a nonzero desktop SessionId may use
  `Get-Clipboard` or `Set-Clipboard`.
- macOS clipboard access must stay in the current user's Aqua LaunchAgent.
- Support only `TEXT` and `PNG` protocol payloads. Clipboard images are enabled
  by default; copied files and file lists are out of scope.
- Limit UTF-8 text to 1 MiB and normalized PNG data to 16 MiB.
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
- Use generated, non-sensitive text and test images to test each direction
  separately.
- Verify no echo loop, queues eventually return to zero, and one persistent
  `stream` SSH process carries normal traffic.
- Do not add files, rich text, history, iPhone or cloud features unless scope
  is explicitly expanded.
- All changes must remain reversible with the included uninstall scripts.

Before release, run `tests/validate-windows.ps1` and
`tests/validate-macos.zsh`. These do not replace a real two-GUI-session
clipboard acceptance test.
