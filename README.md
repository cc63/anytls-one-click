# AnyTLS Server 一键脚本

基于官方 [`anytls/anytls-go`](https://github.com/anytls/anytls-go) reference server 的 Linux 管理脚本，支持 Debian/Ubuntu、CentOS/RHEL、Rocky Linux、AlmaLinux 和 Fedora，支持 `amd64`、`arm64`。

## 一键安装

在 VPS 的 `root` 终端执行：

```bash
wget -O anytls.sh --https-only https://raw.githubusercontent.com/cc63/anytls-one-click/main/anytls.sh && chmod +x anytls.sh && ./anytls.sh
```

非 `root` 用户可以改用：

```bash
wget -O anytls.sh --https-only https://raw.githubusercontent.com/cc63/anytls-one-click/main/anytls.sh && chmod +x anytls.sh && sudo ./anytls.sh
```

## 功能

- 自动从 GitHub 官方 Release 检测并安装最新版 AnyTLS，并校验官方 SHA-256 摘要
- 一键更新核心，保留原配置；新版本启动失败自动回滚
- 独立低权限系统用户和经过加固的 systemd 服务
- 安装、更新、卸载、启动、停止、重启、状态和实时日志
- 修改监听地址、TCP 端口、密码、日志级别
- 查看、重置、编辑并验证 Padding Scheme
- 自动识别活动的 UFW/firewalld，并跟踪脚本自己添加的规则
- 输出标准 AnyTLS URI、sing-box JSON 和 Mihomo/Clash.Meta YAML
- 可选启用 BBR 与 TCP Fast Open
- 同时支持交互菜单与命令行子命令

常用非交互入口：

```bash
sudo ./anytls.sh update
sudo ./anytls.sh config
sudo ./anytls.sh show
sudo ./anytls.sh status
sudo ./anytls.sh logs
```

## 文件位置

| 文件 | 用途 |
|---|---|
| `/usr/local/bin/anytls-server` | 官方服务端核心 |
| `/etc/anytls/config.env` | 监听地址、端口、密码、日志级别 |
| `/etc/anytls/padding.conf` | Padding Scheme |
| `/etc/anytls/version` | 已安装版本记录 |
| `/etc/systemd/system/anytls-server.service` | systemd 服务 |
| `/etc/sysctl.d/99-anytls.conf` | 可选 BBR/TFO 配置 |

## 重要说明

官方 `anytls-go` 是参考实现，服务端只暴露监听地址、密码和 Padding Scheme 三类参数，并在每次启动时生成自签 TLS 证书。因此脚本导出的客户端配置会开启 `insecure` / `skip-cert-verify`。如果需要受信任证书、多用户或更完整的 TLS 控制，建议改用带 AnyTLS 入站的 sing-box/mihomo 服务端实现。

密码会写入仅 `root:anytls` 可读的配置文件；由于官方服务端只能通过 `-p` 参数接收密码，运行进程的命令行中仍可能看到该密码。

云服务器的安全组不属于 VPS 本机防火墙，安装后仍需确认云控制台已放行所选 TCP 端口。
