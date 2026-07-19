# AnyTLS 一键搭建脚本

一个仓库提供两种 AnyTLS 服务端脚本：

- `anytls-ubuntu.sh`：面向 Ubuntu 的完整证书版，基于 sing-box AnyTLS 入站，支持 Let's Encrypt 自动申请和续期，推荐使用。
- `anytls.sh`：基于官方 `anytls-go` reference server 的轻量版，支持多种 Linux 发行版，但只能使用运行时自签证书。

## Ubuntu 证书版一键安装

适用 Ubuntu 20.04/22.04/24.04 及更新版本，支持 `amd64` 和 `arm64`。在 VPS 的 `root` 终端执行：

```bash
apt-get update && apt-get install -y curl && curl -LfsS https://raw.githubusercontent.com/cc63/anytls-one-click/main/anytls-ubuntu.sh -o /tmp/anytls-ubuntu.sh && chmod +x /tmp/anytls-ubuntu.sh && bash /tmp/anytls-ubuntu.sh
```

如果当前不是 `root`：

```bash
sudo apt-get update && sudo apt-get install -y curl && curl -LfsS https://raw.githubusercontent.com/cc63/anytls-one-click/main/anytls-ubuntu.sh -o /tmp/anytls-ubuntu.sh && chmod +x /tmp/anytls-ubuntu.sh && sudo bash /tmp/anytls-ubuntu.sh
```

进入菜单后选择 `1) 安装/重新安装`。如果已经准备好域名，证书模式选择 `1) 自动申请 Let's Encrypt`。

### 申请证书前提

1. 域名已添加 A 或 AAAA 记录，并指向当前 VPS。
2. 使用 Cloudflare DNS 时先关闭代理小云朵，设为 `DNS only`。
3. VPS 本机防火墙和云厂商安全组放行 `80/TCP` 和 AnyTLS 监听端口（默认 `443/TCP`）。
4. 安装时 `80/TCP` 未被 Nginx、Apache 或其他程序占用。Certbot 续期时也需要该端口。

脚本会在申请前检查 DNS 解析、公网 IPv4/IPv6 和端口占用。Certbot 定时器会自动续期，续期成功后自动更新 AnyTLS 证书并重启服务。

## Ubuntu 证书版功能

- 一键申请 Let's Encrypt 证书、自动续期、续期测试和证书状态查看
- 支持导入已有证书/Cloudflare Origin 证书，也可生成自签证书
- 自动安装最新稳定版 sing-box，使用 GitHub Release 提供的 SHA-256 摘要校验安装包
- 一键更新 sing-box 核心，新版本校验或启动失败时自动回滚
- 多用户添加、删除和密码重置
- 监听端口、连接地址、日志级别和 Padding Scheme 管理
- 输出 AnyTLS URI、sing-box JSON 和 Mihomo/Clash.Meta YAML
- 安装、卸载、启动、停止、重启、状态和实时日志
- 自动识别活动的 UFW，只跟踪和删除脚本自己添加的规则
- 独立低权限系统用户和经过加固的 systemd 服务
- 可选启用 BBR、FQ 和 TCP Fast Open

安装后可重新下载脚本，然后直接使用子命令：

```bash
sudo bash anytls-ubuntu.sh update
sudo bash anytls-ubuntu.sh cert
sudo bash anytls-ubuntu.sh renew
sudo bash anytls-ubuntu.sh users
sudo bash anytls-ubuntu.sh config
sudo bash anytls-ubuntu.sh show
sudo bash anytls-ubuntu.sh status
sudo bash anytls-ubuntu.sh logs
```

### Ubuntu 证书版文件位置

| 文件 | 用途 |
|---|---|
| `/usr/local/bin/sing-box-anytls` | sing-box 服务端核心 |
| `/etc/anytls-singbox/config.json` | sing-box AnyTLS 入站配置 |
| `/etc/anytls-singbox/state.env` | 脚本状态 |
| `/etc/anytls-singbox/users.json` | AnyTLS 用户 |
| `/etc/anytls-singbox/padding.json` | Padding Scheme |
| `/etc/anytls-singbox/cert/` | 服务读取的证书副本 |
| `/etc/letsencrypt/` | Certbot 证书和续期配置 |
| `/etc/systemd/system/anytls-singbox.service` | systemd 服务 |

## 多系统轻量版

如果没有域名，或者需要在 Debian、CentOS/RHEL、Rocky Linux、AlmaLinux 和 Fedora 上使用官方 reference server，可执行：

```bash
wget -O anytls.sh --https-only https://raw.githubusercontent.com/cc63/anytls-one-click/main/anytls.sh && chmod +x anytls.sh && ./anytls.sh
```

该版基于官方 [`anytls/anytls-go`](https://github.com/anytls/anytls-go)，支持更新回滚、Padding Scheme、UFW/firewalld、客户端配置导出和 BBR。由于官方 reference server 不支持读取外部证书，客户端必须开启 `insecure` / `skip-cert-verify`。

## 上游项目

- [SagerNet/sing-box](https://github.com/SagerNet/sing-box)
- [anytls/anytls-go](https://github.com/anytls/anytls-go)
- [certbot/certbot](https://github.com/certbot/certbot)

> 仅用于合法的网络管理、隐私保护与安全测试。使用者应遵守所在地法律、服务商条款及网络管理规定。
