# Agent instructions

This repository installs a text-only clipboard bridge between one macOS GUI
login session and one Windows GUI login session.

## Architecture invariants

- The Mac is the only SSH client; Windows runs OpenSSH Server.
- One persistent SSH process carries both directions:
  - Mac→Windows: `SET` frames on SSH stdin.
  - Windows→Mac: `SET` frames on SSH stdout.
  - Each receiver returns an `ACK` frame.
- Local clipboard checks may be periodic, but do not replace the persistent SSH
  stream with repeated SSH `fetch` commands.
- The Windows OpenSSH session never calls `Set-Clipboard` or `Get-Clipboard`.
- Only `windows/agent.ps1`, running in the interactive user's nonzero session,
  accesses the Windows clipboard.
- Only the macOS LaunchAgent in the Aqua GUI domain accesses `pbcopy`/`pbpaste`.
- Do not add AppleScript, `osascript`, Accessibility, Terminal automation, or
  UI scripting.

## Before changing or installing anything

1. Detect the current platform.
2. Obtain the Windows hostname/IP, Windows username, administrator membership,
   network scope, and repository paths.
3. Ask for the Mac public-key path only. Never request a private key.
4. Verify the Windows host key and then verify:

   ```zsh
   ssh -o BatchMode=yes <target> "whoami"
   ```

5. If the agent cannot reach both local machines, provide commands for the user
   to run locally. Do not pretend Codex Cloud can reach a private LAN.

## Installation order

1. Configure Windows OpenSSH Server from Microsoft's current documentation.
2. Install the Mac public key in the correct Windows authorized-keys file:
   - standard user: `%USERPROFILE%\.ssh\authorized_keys`
   - administrator: `%ProgramData%\ssh\administrators_authorized_keys`
3. Run `windows/install.ps1` in the logged-in Windows user's PowerShell.
4. Verify `windows/status.ps1` reports `Running=True` and `SessionId != 0`.
5. Run `macos/install.zsh <ssh-target>` locally on the Mac.
6. Verify `macos/status.zsh`.

## Acceptance test

- Use random, non-sensitive text generated for the test.
- Do not read, print, log, save, or upload the pre-existing clipboard.
- Verify Mac→Windows and Windows→Mac separately.
- Verify content using a hash or an exact comparison held only in process
  memory; do not print the text.
- Verify no echo loop and that queue files return to zero.
- Verify only one long-running SSH `stream` process exists during normal use.
- Leave a nonempty test marker in the clipboard rather than clearing it.

## Safety and scope

- Never output credentials, private keys, tokens, or clipboard bodies.
- Never disable SSH host-key checking.
- Never expose TCP 22 to the public Internet as part of this project.
- Do not add image, file, rich-text, history, iPhone, cloud relay, or account
  features unless the user explicitly expands scope.
- Preserve unrelated SSH configuration and existing keys.
- All install changes must be reversible using the included uninstall scripts.

## Definition of done

- PowerShell files parse on Windows PowerShell 5.1.
- Zsh files pass `zsh -n`; the plist passes `plutil -lint`.
- The Windows GUI agent has one instance and a nonzero SessionId.
- One persistent SSH session carries both directions without repeated fetches.
- Both text directions pass, without an extra reverse event.
- Queue payloads eventually return to zero after acknowledgement and GUI-agent
  processing.
- Documentation states the plaintext-at-rest and latest-state-only limits.
