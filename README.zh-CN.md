# Mac–Windows SSH 双向剪贴板

这是一个尽量简单的 **macOS ↔ Windows 双向纯文本剪贴板桥**。

## 核心设计

只要求 **Mac 能 SSH 到 Windows**。Windows 不需要 SSH 回 Mac，也不需要在
Mac 开启“远程登录”。

Mac 建立一条长期运行的 SSH 会话：

- Mac → Windows：通过该会话的标准输入发送文本；
- Windows → Mac：通过同一会话的标准输出推送文本；
- 接收端发送 `ACK` 后，发送端才删除待发送文件；
- 连接中断后自动重连，并重新发送尚未确认的最新状态。

因此，**网络层不是每 0.5 秒发起一次 SSH 查询**，而是一条全双工长连接。
两端仍分别每 0.2 秒和 0.25 秒检查一次本机剪贴板是否变化，Windows SSH
中继每 0.05 秒检查一次本机私有队列，因为
`pbpaste` 与 Windows PowerShell 剪贴板接口没有可供本项目直接订阅的统一
跨平台事件 API。这些本地检查不建立新连接，也不产生周期性网络请求；
一旦发现变化，就立即写入已经打开的 SSH 字节流。

Windows 的 OpenSSH 非交互会话通常不在桌面会话中，不能可靠地直接操作
桌面剪贴板。本项目因此把职责分开：

1. SSH 会话只负责加密传输和读写当前用户的私有队列；
2. `windows/agent.ps1` 在已登录的 Windows 桌面会话中访问剪贴板；
3. macOS LaunchAgent 在当前用户的 Aqua/GUI 会话中访问 `pbcopy`/`pbpaste`。

这不是 SSH `-L`/`-R` 端口转发；它使用普通 SSH 远程进程的标准输入/输出。

## 前提条件

- Windows 10 1809+ 或 Windows 11，PowerShell 5.1+；
- Mac 与 Windows 位于同一可信局域网或同一私有 VPN；
- Windows 已安装并启动 OpenSSH Server；
- Mac 可以无交互执行：

  ```zsh
  ssh -o BatchMode=yes Windows别名 "whoami"
  ```

- 两台机器均已登录各自的桌面用户；
- 当前版本只同步 1 MiB 以内的非空纯文本。

全新电脑请先阅读
[《从零建立 Mac→Windows SSH》](docs/NEW-COMPUTER-SETUP.zh-CN.md)。

## 安装

先在 Windows 当前桌面用户的普通 PowerShell 中运行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\windows\install.ps1
```

安装器会：

- 将程序复制到 `%LOCALAPPDATA%\MacWindowsSSHClipboard`；
- 将该目录权限收紧到当前用户、SYSTEM 和本地 Administrators；
- 启动当前桌面会话中的剪贴板 Agent；
- 添加当前用户登录启动项。

然后在 Mac 本地运行：

```zsh
chmod +x macos/*.zsh
./macos/install.zsh my-windows
```

`my-windows` 推荐使用 `~/.ssh/config` 中的别名，也可使用
`Windows用户名@Windows地址`。

Mac 安装器不会控制 Terminal，也不会申请 Accessibility/Automation 权限。
它使用当前用户的 `launchd` Aqua/GUI 服务。

## 验证

Windows：

```powershell
& "$env:LOCALAPPDATA\MacWindowsSSHClipboard\status.ps1"
```

期望：

- `Running = True`
- `SessionId` 不是 `0`

Mac：

```zsh
./macos/status.zsh
```

期望：

- `running=yes`
- `ssh_target_configured=yes`
- `windows_reachable=yes`

再分别复制一段不敏感的测试文本，确认另一端可以粘贴。不要用密码、验证码、
恢复短语或私钥做第一次测试。

## 停止与卸载

只停止 Windows 桌面 Agent：

```powershell
& "$env:LOCALAPPDATA\MacWindowsSSHClipboard\stop.ps1"
```

重新启动：

```powershell
& "$env:LOCALAPPDATA\MacWindowsSSHClipboard\start.ps1"
```

完全卸载时，先在 Mac 执行：

```zsh
./macos/uninstall.zsh
```

再在 Windows 执行：

```powershell
.\windows\uninstall.ps1
```

## 能力边界

- 网络使用一条持久 SSH 全双工流；断线后默认 1 秒重连；
- 本机剪贴板检测间隔：Mac 约 0.2 秒，Windows 约 0.25 秒；
- 同一局域网正常负载下，设计目标是亚秒级体感，但实际延迟取决于系统调度、
  SSH 重连和机器睡眠状态；
- 快速连续复制时可能只同步最后一个状态，不保证保存每个中间事件；
- Mac 离线时，Windows 只保留最后一份待发送文本，重连后继续发送；
- 两个方向的队列文本都可能短暂以明文存在当前 Windows 用户的私有目录；
- Mac→Windows 的 `ACK` 表示消息已持久写入私有队列，桌面 Agent 处理后
  删除；Windows→Mac 的 `ACK` 会删除对应待发文件；
- 普通文件系统删除不等于安全擦除；
- 空剪贴板不会同步，避免意外清空另一台机器；
- 不处理图片、文件、富文本、剪贴板历史或 iPhone。

## 安全边界

- 传输加密由 SSH 提供，不另加应用层端到端加密；
- 不要把 Windows 的 TCP 22 直接暴露到公网，使用局域网或私有 VPN；
- 不要向 AI 提供 SSH 私钥、密码、token 或真实剪贴板正文；
- 项目默认信任两台已登录机器及相应用户账户；
- 剪贴板可能包含敏感内容，启用全量同步前应理解上述明文落盘边界。

## 交给 Codex 的信息

可以提供：

- Windows 的局域网 IP、主机名或 SSH 别名；
- Windows 登录用户名及是否属于 Administrators；
- Mac 公钥文件的路径，例如 `~/.ssh/id_ed25519.pub`；
- 两台机器是否位于同一局域网或 VPN；
- 项目在两台机器上的路径。

不要提供：

- SSH 私钥正文；
- Windows 或 Mac 密码；
- token；
- 真实剪贴板正文。

可直接使用
[Codex 安装提示词](docs/CODEX-PROMPT.zh-CN.md)。
Codex Cloud 通常无法直接访问家庭局域网；它可以修改仓库，但实际安装与
验收应由本地 Codex、人工终端或已连接的自托管 runner 完成。

## License

MIT
