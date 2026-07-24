# 给本地 Codex 的安装提示词

复制下面内容，替换尖括号中的信息。不要粘贴私钥或密码。

```text
请帮我安装并验收 mac-windows-ssh-clipboard。

环境：
- Windows 版本：<版本>
- Windows 用户名：<用户名>
- Windows 用户是否为管理员：<是/否/未知>
- Windows 局域网 IP 或主机名：<地址>
- Mac 版本：<版本>
- 两台机器网络：<同一局域网/同一 VPN>
- Mac 公钥路径：<例如 ~/.ssh/id_ed25519.pub>
- 项目在 Windows 的路径：<路径>
- 项目在 Mac 的路径：<路径>

约束：
1. 先检查当前平台，不能混用 macOS 和 Windows 命令。
2. 不得读取、输出或上传 SSH 私钥、密码、token 或真实剪贴板正文。
3. 不得使用 AppleScript、osascript、Terminal UI 自动化或 Accessibility。
4. 只建立 Mac→Windows 的 SSH 登录；不要开启 Windows→Mac SSH。
   正常运行时应保持一条 SSH 长连接，通过 stdin/stdout 双向传输，不要用
   周期性 SSH fetch 代替长连接。
5. Windows sshd 的非交互会话不能直接操作桌面剪贴板。必须让
   windows/agent.ps1 运行在当前桌面用户的非零 SessionId。
6. 如果 OpenSSH Server 未安装，按微软官方步骤安装、启动并检查防火墙。
7. 根据 Windows 用户是否为管理员，把 Mac 公钥放到正确位置并设置 ACL。
8. 先验证：
   ssh -o BatchMode=yes <目标> "whoami"
9. 再运行 Windows 安装器，然后运行 Mac 安装器。
10. 使用随机、不敏感的测试文本验证两个方向；不要打印测试前剪贴板。
11. 验收需要确认两个方向内容一致、没有回环、队列最终为空。
12. 任何步骤失败都应停止并报告，不要关闭主机密钥校验，不要使用默认值
    假装成功。
```

Codex Cloud 可以帮助修改仓库，但通常不能直接访问家庭局域网。安装动作
应交给本地 Codex、人工终端或已连接的自托管 runner。
