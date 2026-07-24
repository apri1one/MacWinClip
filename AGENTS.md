# Agent rules

This repository installs a plain-text clipboard bridge between one macOS GUI
session and the matching Windows GUI user.

## Invariants

- Detect the current OS before running commands.
- Mac is the only SSH client; Windows runs OpenSSH Server.
- Keep one persistent SSH process: Mac→Windows uses stdin, Windows→Mac stdout.
- Never let the Windows SSH/Session 0 process access the desktop clipboard.
- Only `windows/agent.ps1` in a nonzero desktop SessionId may use
  `Get-Clipboard` or `Set-Clipboard`.
- macOS clipboard access must stay in the current user's Aqua LaunchAgent.
- Do not use AppleScript, `osascript`, Terminal control, Accessibility or UI
  automation.

## Installation

1. Follow `docs/NEW-COMPUTER-SETUP.zh-CN.md`.
2. Verify the Windows host key and:

   ```zsh
   ssh -o BatchMode=yes <target> "whoami"
   ```

3. Run `windows/install.ps1` as the logged-in Windows desktop user.
4. Require `Running=True` and `SessionId != 0`.
5. Run `macos/install.zsh <target>` locally on the Mac.
6. Verify `macos/status.zsh`.

The SSH user and Windows desktop Agent user must be the same account. Codex
Cloud must not claim it can reach a private LAN unless an explicit runner or
route has been verified.

## Safety and acceptance

- Never read, print, log or upload pre-existing clipboard contents.
- Never request or expose private keys, passwords or tokens.
- Preserve existing SSH configuration and host-key checking.
- Do not expose TCP 22 to the public Internet.
- Use generated, non-sensitive text to test each direction separately.
- Verify no echo loop, queues eventually return to zero, and one persistent
  `stream` SSH process carries normal traffic.
- Do not add files, images, rich text, history, iPhone or cloud features unless
  scope is explicitly expanded.
- All changes must remain reversible with the included uninstall scripts.

Before release, run `tests/validate-windows.ps1` and
`tests/validate-macos.zsh`. These do not replace a real two-GUI-session
clipboard acceptance test.
