# MacWinClip

一个无账号、无云中继、基于 SSH 长连接的 macOS ↔ Windows 双向纯文本
剪贴板桥。

> **Beta 状态：**隔离安装、协议、ACL、卸载和跨平台语法验证已经通过；
> 尚未在一组全新 Windows GUI 用户与全新 macOS Aqua 用户上完成真实剪贴板
> 端到端验收。当前版本适合测试，不应视为已经完成生产级双机认证。

## 工作方式

只需要 **Mac 能 SSH 登录 Windows**。Windows 不需要 SSH 回 Mac，也不需要
在 Mac 开启“远程登录”。

Mac 保持一条 SSH 长连接：

```text
Mac ── SSH stdin  ──> Windows
Mac <─ SSH stdout ─── Windows
```

- 网络层使用同一条全双工连接，不会每隔几百毫秒重新执行 SSH `fetch`；
- Mac 每约 0.2 秒、Windows 每约 0.25 秒检查本机剪贴板；
- Windows SSH 中继每约 0.05 秒检查本机私有队列；
- 上述检查都发生在本机，发现变化后才写入已打开的 SSH 字节流；
- `SET/ACK`、断线重连和内容状态抑制用于减少丢失与回环。

Windows 的 SSH 非交互进程通常不能可靠访问桌面剪贴板。因此本项目另有一个
运行在当前 Windows 桌面会话中的 Agent；macOS 端则运行在当前用户的
Aqua/GUI LaunchAgent 中。

## 前提条件

- Windows 10 1809+ 或 Windows 11；
- Windows PowerShell 5.1+；
- Windows 已安装并启动 OpenSSH Server；
- Mac 与 Windows 位于同一可信局域网或私有 VPN；
- SSH 用户必须与运行 Windows 剪贴板 Agent 的桌面用户相同；
- Mac 可以无交互执行：

  ```zsh
  ssh -o BatchMode=yes <Windows别名> "whoami"
  ```

第一次配置 SSH，请按
[《从零建立 Mac→Windows SSH》](docs/NEW-COMPUTER-SETUP.zh-CN.md)
完成 OpenSSH Server、公钥位置、ACL、主机指纹和 SSH alias 配置。

## 安装

### 1. Windows

在当前桌面用户的普通 PowerShell 中，从仓库根目录运行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\windows\install.ps1
```

安装位置：

```text
%LOCALAPPDATA%\MacWindowsSSHClipboard
```

安装器会收紧目录 ACL、启动桌面 Agent，并为当前用户创建登录启动项。

### 2. Mac

```zsh
zsh ./macos/install.zsh <Windows别名>
```

安装器使用当前用户的 Aqua LaunchAgent，不会使用 AppleScript、Terminal
控制、Accessibility 或 Automation 权限。

## 状态、停止与卸载

Windows 状态：

```powershell
& "$env:LOCALAPPDATA\MacWindowsSSHClipboard\status.ps1"
```

应看到 `Running = True`，且 `SessionId` 不是 `0`。

Mac 状态：

```zsh
~/.local/share/mac-windows-ssh-clipboard/status.zsh
```

应看到：

```text
running=yes
ssh_target_configured=yes
windows_reachable=yes
```

停止或重新启动 Windows Agent：

```powershell
& "$env:LOCALAPPDATA\MacWindowsSSHClipboard\stop.ps1"
& "$env:LOCALAPPDATA\MacWindowsSSHClipboard\start.ps1"
```

完全卸载时先卸载 Mac，再卸载 Windows：

```zsh
~/.local/share/mac-windows-ssh-clipboard/uninstall.zsh
```

```powershell
& "$env:LOCALAPPDATA\MacWindowsSSHClipboard\uninstall.ps1"
```

## 验收

分别在 Mac 和 Windows 复制一段不敏感文本，确认另一端可以粘贴；再观察
是否发生反向回环。不要用密码、验证码、恢复短语或私钥做测试。

不接触剪贴板的开发验证：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\validate-windows.ps1
```

```zsh
zsh ./tests/validate-macos.zsh
```

## 能力与安全边界

- 只同步 1 MiB 以内的非空纯文本；
- 快速连续复制时以最新状态为主，不保证保存每个中间事件；
- 同时在两端复制属于冲突场景，不提供全局顺序保证；
- 机器睡眠或网络中断时暂停，恢复后自动重连；
- 两个方向的队列正文都可能短暂明文落在当前 Windows 用户的私有目录；
- 确认和处理后会删除队列文件，但普通删除不等于安全擦除；
- SSH 提供传输加密，本项目不另加应用层端到端加密；
- 不要把 TCP 22 直接暴露到公网，使用可信局域网或私有 VPN；
- 不支持图片、文件、富文本、历史记录、iPhone 或云同步。

## 交给 Codex 安装

建议使用本地 Codex，并提供：

- Windows SSH alias，或 Windows 用户名与局域网地址；
- Windows 用户是否属于 Administrators；
- Mac **公钥文件路径**，例如 `~/.ssh/id_ed25519.pub`；
- 两台机器上的仓库路径和网络关系。

不要提供 SSH 私钥正文、系统密码、token 或真实剪贴板内容。要求 Codex
先阅读本仓库的 `AGENTS.md`，按 Windows → Mac 顺序安装，并用不敏感文本
分别验证两个方向、SessionId、无回环和队列清空。

Codex Cloud 通常无法直接访问家庭局域网，可以修改仓库，但本地安装和验收
仍需本地 Codex、人工终端或明确连接到局域网的 runner。

## License

MIT
