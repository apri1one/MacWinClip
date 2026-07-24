# 从零建立 Mac→Windows SSH

本项目只要求 Mac 能 SSH 登录 Windows。以下步骤主要依据微软官方的
[OpenSSH 安装文档](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse)
和
[密钥认证文档](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement)。

## 1. 准备网络信息

两台机器应位于：

- 同一个可信局域网；或
- 同一个私有 VPN。

不要直接把 Windows 的 TCP 22 端口暴露到公网。

在 Windows PowerShell 查看用户名：

```powershell
whoami
```

查看 IPv4 地址：

```powershell
Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' } |
  Select-Object InterfaceAlias, IPAddress
```

家庭路由器可能通过 DHCP 改变 IP。长期使用时应设置 DHCP 地址保留，
或者使用可解析的主机名。

## 2. 在 Windows 安装 OpenSSH Server

以管理员身份打开 PowerShell：

```powershell
Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH*'
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
```

检查防火墙规则：

```powershell
Get-NetFirewallRule -Name OpenSSH-Server-In-TCP
```

如果该规则不存在：

```powershell
New-NetFirewallRule `
  -Name OpenSSH-Server-In-TCP `
  -DisplayName 'OpenSSH Server (sshd)' `
  -Enabled True `
  -Direction Inbound `
  -Protocol TCP `
  -Action Allow `
  -LocalPort 22 `
  -Profile Private `
  -RemoteAddress LocalSubnet
```

该命令只允许专用网络中的本地子网访问。使用私有 VPN 时，应把
`LocalSubnet` 替换为明确的 VPN 地址段或 Mac 的 VPN 地址，不要改成
`Any`。

## 3. 在 Mac 创建 SSH 密钥

建议为 MacWinClip 创建独立的 Ed25519 密钥，避免与 GitHub、服务器或其他
设备共用同一私钥。先检查是否已经存在：

```zsh
test -f ~/.ssh/macwinclip_ed25519 && echo "已有密钥" || echo "尚未创建"
```

只有不存在时才创建：

```zsh
ssh-keygen -t ed25519 -f ~/.ssh/macwinclip_ed25519
```

私钥是 `~/.ssh/macwinclip_ed25519`，绝不能发送给别人或 AI。

可以分享的是公钥：

```zsh
cat ~/.ssh/macwinclip_ed25519.pub
```

当前 Beta 使用的是普通 Windows SSH 登录。这个公钥授予目标 Windows
账户完整的 SSH Shell，不是“只能访问剪贴板”的受限密钥。应优先使用
非管理员 Windows 桌面账户，并把 Mac 和私钥都视为同一安全边界。

## 4. 把 Mac 公钥安装到 Windows

先在 Windows 检查目标用户是否属于管理员组：

```powershell
(New-Object Security.Principal.WindowsPrincipal(
  [Security.Principal.WindowsIdentity]::GetCurrent()
)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
```

### 普通 Windows 用户

公钥应放入：

```text
C:\Users\<用户名>\.ssh\authorized_keys
```

在 Windows 当前用户 PowerShell 中：

```powershell
New-Item -ItemType Directory -Force "$HOME\.ssh"
notepad "$HOME\.ssh\authorized_keys"
```

将 Mac 的 `.pub` 公钥完整粘贴为一行并保存。

### Windows 管理员用户

微软默认配置通常要求把公钥放入：

```text
C:\ProgramData\ssh\administrators_authorized_keys
```

以管理员身份编辑该文件，然后设置 ACL：

```powershell
icacls.exe "$env:ProgramData\ssh\administrators_authorized_keys" `
  /inheritance:r `
  /grant "*S-1-5-32-544:F" `
  /grant "*S-1-5-18:F"
```

`S-1-5-32-544` 是本地 Administrators，`S-1-5-18` 是 SYSTEM；使用 SID
可避免中文 Windows 的本地化组名问题。

## 5. 从 Mac 首次连接

```zsh
ssh Windows用户名@Windows_IP
```

首次连接会显示 Windows SSH 主机指纹。应在 Windows 本机核对后再接受，
不能无脑输入 `yes`。

确认能登录后退出：

```text
exit
```

## 6. 创建 SSH 别名

编辑 Mac 的 `~/.ssh/config`：

```sshconfig
Host my-windows
    HostName 192.168.x.x
    User Windows用户名
    IdentityFile ~/.ssh/macwinclip_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 15
    ServerAliveCountMax 3
```

设置权限并验证无交互登录：

```zsh
chmod 700 ~/.ssh
chmod 600 ~/.ssh/config
ssh -o BatchMode=yes my-windows "whoami"
```

只有这条命令成功后，才安装剪贴板桥。

## 7. 常见失败

- `Connection refused`：`sshd` 未启动、端口不通或防火墙阻止。
- `Permission denied (publickey)`：公钥文件位置或 ACL 错误。
- 管理员账号使用了用户目录中的 `authorized_keys`：检查
  `C:\ProgramData\ssh\sshd_config` 的 `Match Group administrators`。
- IP 变化：设置 DHCP 保留或更新 SSH alias。
- Mac 能 SSH，但 Windows 剪贴板不变：Windows 桌面 Agent 没有运行，
  或它错误地运行在 Session 0。
