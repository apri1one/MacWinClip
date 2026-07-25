# MacWinClip

一个无第三方账号、无云中继、基于 SSH 长连接的 macOS ↔ Windows 双向
文本、图片与普通文件剪贴板桥。文本和截图默认自动同步，文件功能仍处于
Beta 阶段。

> **Beta 状态：**隔离安装、协议、ACL、卸载和跨平台语法验证已经通过；
> 也已在一组真实 Windows GUI 与 macOS Aqua 用户会话中完成双向文本、截图、
> 队列清空及无回环验收。尚未用一组全新安装的双机环境完成从零验收，当前
> 版本仍适合测试，不应视为已经完成生产级双机认证。
>
> **文件模式开发状态：**文件协议、10 GiB 限制、路径校验、SHA-256、
> Windows 隔离安装与 macOS 编译测试已经通过。Windows→Mac 当前仍在复制后
> 立即传输；Mac→Windows 已改为复制时只发送清单、Windows 请求文件内容时
> 才开始传输。按需传输的隔离协议测试，以及包含中文文件名的
> Finder→资源管理器真实粘贴验收均已通过。文件夹暂不支持。

## 工作方式

只需要 **Mac 能 SSH 登录 Windows**。Windows 不需要 SSH 回 Mac，也不需要
在 Mac 开启“远程登录”。

Mac 保持一条 Windows→Mac 的 SSH 长连接；反向传输只在剪贴板变化时触发：

```text
Mac <── 持久 SSH stdout ─── Windows
Mac ── SCP + 短 SSH 提交 ──> Windows
Mac ── 短 SSH ACK ─────────> Windows
```

普通文件不会放进 Base64 文本协议。Windows→Mac 时，复制后由长连接发送
清单，Mac 再通过 SCP 拉取文件。Mac→Windows 时，复制后只先发送文件名和
大小；Windows 以虚拟文件形式写入剪贴板，资源管理器或其他目标应用请求
文件内容后，才通过长连接发送 `FETCH`，Mac 随后通过 SCP 上传正文。
两端使用独立文件工作进程和原生进度窗口，因此大文件传输不会阻塞文本与
截图同步。

- 不会每隔几百毫秒通过网络执行 SSH `fetch`；Mac→Windows 文件正文只在
  Windows 应用请求内容后传输；
- Mac 每约 0.2 秒、Windows 每约 0.25 秒检查本机剪贴板；
- Windows SSH 中继每约 0.05 秒检查本机私有队列；
- 上述检查都发生在本机；Windows 变化写入已打开的 SSH 字节流，Mac 变化
  通过 SCP 上传后由短 SSH 命令原子提交；
- `SET/ACK`、断线重连和内容状态抑制用于减少丢失与回环。

Windows 的 SSH 非交互进程通常不能可靠访问桌面剪贴板。因此本项目另有一个
运行在当前 Windows 桌面会话中的 Agent；macOS 端则运行在当前用户的
Aqua/GUI LaunchAgent 中。

## 前提条件

- Windows 10 1809+ 或 Windows 11；
- Windows PowerShell 5.1+；
- Windows 已安装并启动 OpenSSH Server；
- Mac 已安装 Apple Command Line Tools，可执行
  `xcrun --find swiftc`；若缺少，先运行 `xcode-select --install`；
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

**Windows 和 Mac 两端都要安装。**Windows 运行桌面剪贴板 Agent 和 SSH
中继；Mac 运行 SSH 长连接客户端。

安装前先决定是否启用自动启动。这里的“开机启动”准确说是**用户登录图形
桌面后启动**；登录前没有可访问的用户剪贴板。默认启用，适合长期使用。
启用后程序会在后台持续观察并同步以后复制的文本、图片与普通文件。

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

如果只想当前登录期间使用，不希望下次登录自动启动：

```powershell
.\windows\install.ps1 -NoAutoStart
```

这仍会立即启动当前 Windows Agent，但不会创建登录启动项。

### 2. Mac

```zsh
zsh ./macos/install.zsh <Windows别名>
```

安装器会用 Apple Command Line Tools 在本机编译剪贴板辅助程序，并使用
当前用户的 Aqua LaunchAgent；不会使用 AppleScript、Terminal 控制、
Accessibility 或 Automation 权限。

如果不希望登录后自动启动：

```zsh
zsh ./macos/install.zsh --no-autostart <Windows别名>
```

该模式只安装文件和配置，不启动后台桥。需要使用时在 Mac 前台运行：

```zsh
zsh ~/.local/share/mac-windows-ssh-clipboard/bridge.zsh
```

## 状态、停止与卸载

Windows 状态：

```powershell
& "$env:LOCALAPPDATA\MacWindowsSSHClipboard\status.ps1"
```

应看到 `Running = True`，且 `SessionId` 不是 `0`。
文件传输期间 `ActiveFileTransfers` 会大于 `0`。

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

分别在 Mac 和 Windows 复制一段不敏感文本，确认另一端可以粘贴。再分别
把一张测试截图复制到剪贴板，确认另一端能粘贴图片，并观察是否发生反向
回环。不要用密码、验证码、恢复短语、私钥或敏感截图做测试。

- Windows：用截图工具截取后，确保截图进入剪贴板；
- Mac：使用 `Control-Shift-Command-3/4`，或在“截屏”选项中选择复制到
  剪贴板。

再准备一个不敏感的小文件测试两个方向：

- Finder→Windows：在 Finder 复制后先等待，确认没有进度窗口；在 Windows
  资源管理器中粘贴时才应出现两端进度窗口并开始传输；
- Windows→Finder：当前版本在资源管理器复制后立即开始传输，完成后再到
  Finder 粘贴。

接收文件实体保留在当前用户的 `Downloads/MacWinClip`。Windows 的
Mac→Windows 按需模式使用虚拟文件剪贴板；其他已完成接收的文件剪贴板保存
本地文件路径。

不接触剪贴板的开发验证：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\validate-windows.ps1
```

```zsh
zsh ./tests/validate-macos.zsh
```

## 能力与安全边界

- 默认同步 1 MiB 以内的非空纯文本，以及 16 MiB 以内的剪贴板图片；
- 图片在传输前统一为 PNG；支持截图和应用中“复制图片”；
- 默认同步 Finder 或资源管理器中复制的普通文件：单次最多 1000 个、总计
  最多 10 GiB；不支持文件夹、符号链接、剪切/移动语义和空文件集合；
- Mac→Windows 复制时只同步清单，目标应用请求文件正文后才传输；剪贴板
  管理器或其他程序若主动读取虚拟文件正文，也会触发传输，系统无法可靠地
  区分这种读取与用户粘贴；
- Windows→Mac 当前仍是复制后立即传输，尚未改为 Finder 文件承诺模式；
- 文件使用 SCP 流式传输并进行 SHA-256 校验，不会整体读入内存；传输时
  Windows 和 Mac 都会显示进度、速度、预计剩余时间、校验状态与取消按钮；
- 实际传输开始后，发送端会先把所选文件流式暂存到当前用户私有缓存，发送
  期间需要最多约等于本次文件总大小的额外可用磁盘空间；成功、失败或取消后
  会删除发送缓存；
- Mac 接收文件后会保留一个很小的 pasteboard owner 进程，使 Finder 能持续
  读取文件剪贴板；用户复制任何新内容或停止 MacWinClip 后，该进程会退出；
- 接收文件不会自动删除，因为系统文件剪贴板只保存本地路径；用户可自行
  清理 `Downloads/MacWinClip`；
- 第一版文件传输不支持断点续传；网络中断或失败后需要从头重新复制；
- 快速连续复制时以最新状态为主，不保证保存每个中间事件；
- 同时在两端复制属于冲突场景，不提供全局顺序保证；
- 机器睡眠或网络中断时暂停，恢复后自动重连；
- 两个方向的队列正文都可能短暂明文落在 Windows 用户私有目录或 Mac
  用户私有缓存目录；
- 确认和处理后会删除队列文件，但普通删除不等于安全擦除；
- SSH 提供传输加密，本项目不另加应用层端到端加密；
- 不要把 TCP 22 直接暴露到公网，使用可信局域网或私有 VPN；
- 不支持文件夹、富文本格式、历史记录、iPhone 或云同步。

## 交给 Codex 安装

建议使用本地 Codex，并提供：

- Windows SSH alias，或 Windows 用户名与局域网地址；
- Windows 用户是否属于 Administrators；
- Mac **公钥文件路径**，例如 `~/.ssh/id_ed25519.pub`；
- 两台机器上的仓库路径和网络关系。

不要提供 SSH 私钥正文、系统密码、token 或真实剪贴板内容。要求 Codex
先阅读本仓库的 `AGENTS.md`，**安装前先询问是否启用登录后自动启动**，
再按 Windows → Mac 顺序安装，并用不敏感文本、测试截图和小型普通文件
分别验证两个方向、SessionId、无回环和队列清空。

可以把下面这段和 GitHub 链接一起发给 Agent：

```text
请先完整阅读 README.md 和 AGENTS.md。先询问我是否启用 Windows 与 Mac
用户登录后的自动启动，再按选择安装两端。不得读取或输出真实剪贴板、私钥、
密码或 token。最后验证 Windows SessionId、两个同步方向、无回环和卸载命令。
文本、剪贴板图片和普通文件都应测试；文件测试必须使用新建的不敏感小文件。
不要读取、打印或上传测试前已有的剪贴板内容。
```

Codex Cloud 通常无法直接访问家庭局域网，可以修改仓库，但本地安装和验收
仍需本地 Codex、人工终端或明确连接到局域网的 runner。

## License

MIT
