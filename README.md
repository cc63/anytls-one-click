# AnyTLS 一键搭建脚本

新手优先使用 `anytls-ubuntu.sh`：支持 Ubuntu 20.04/22.04/24.04 及更新版本，支持 `amd64` 和 `arm64`。

## 纯 IP 一键安装（推荐）

不需要域名、邮箱或自己填写配置。在 Ubuntu VPS 的 `root` 终端复制执行：

```bash
apt-get update && apt-get install -y curl && curl -LfsS https://raw.githubusercontent.com/cc63/anytls-one-click/main/anytls-ubuntu.sh -o /tmp/anytls-ubuntu.sh && chmod +x /tmp/anytls-ubuntu.sh && bash /tmp/anytls-ubuntu.sh install-ip
```

非 `root` 用户执行：

```bash
sudo apt-get update && sudo apt-get install -y curl && curl -LfsS https://raw.githubusercontent.com/cc63/anytls-one-click/main/anytls-ubuntu.sh -o /tmp/anytls-ubuntu.sh && chmod +x /tmp/anytls-ubuntu.sh && sudo bash /tmp/anytls-ubuntu.sh install-ip
```

该命令不会询问技术参数，会自动完成：

- 检测 VPS 公网 IPv4，没有 IPv4 时使用 IPv6
- 优先使用 `443/TCP`，被占用时自动选择备用端口
- 生成 48 位随机密码和自签 TLS 证书
- 安装并启动最新稳定版 sing-box AnyTLS
- 应用官方 Padding Scheme、安全权限和 systemd 开机自启
- 如果 UFW 已启用，自动放行 AnyTLS 端口
- 输出可直接导入的 AnyTLS 链接、sing-box JSON 和 Mihomo YAML

安装完成后，只需看脚本最后显示的：

```text
服务器: VPS公网IP
端口: 443
密码: 自动生成
分享链接: anytls://...
```

把 `anytls://...` 复制到客户端即可。纯 IP 模式使用自签证书，因此导出配置会自动开启 `insecure` / `skip-cert-verify`。

> 云厂商的安全组不在 VPS 系统内，脚本无法代为操作。如果客户端连不上，请在云控制台放行安装结果显示的 TCP 端口。

## 有域名的安装方式

需要 Let's Encrypt 受信任证书时，执行：

```bash
apt-get update && apt-get install -y curl && curl -LfsS https://raw.githubusercontent.com/cc63/anytls-one-click/main/anytls-ubuntu.sh -o /tmp/anytls-ubuntu.sh && chmod +x /tmp/anytls-ubuntu.sh && bash /tmp/anytls-ubuntu.sh install-domain
```

脚本只会询问域名和可选邮箱，其他参数全部自动。需要提前准备：

1. 域名 A/AAAA 记录已指向 VPS。
2. Cloudflare 关闭代理小云朵，设为 `DNS only`。
3. 安全组放行 `80/TCP` 和脚本显示的 AnyTLS 端口。
4. `80/TCP` 没有被 Nginx/Apache 占用。

Certbot 定时器会自动续期，续期成功后自动更新 AnyTLS 证书并重启服务。

## 交互菜单

需要更多功能时，不带参数运行：

```bash
bash /tmp/anytls-ubuntu.sh
```

菜单支持：

- 纯 IP、域名证书和高级自定义安装
- Let's Encrypt 申请、自动续期、续期测试、自签或导入证书
- 多用户添加、删除和密码重置
- 端口、连接地址、日志和 Padding Scheme 管理
- 核心更新、失败回滚、服务管理、实时日志和卸载
- 可选 BBR、FQ 和 TCP Fast Open

## 一键更新核心

```bash
curl -LfsS https://raw.githubusercontent.com/cc63/anytls-one-click/main/anytls-ubuntu.sh -o /tmp/anytls-ubuntu.sh && chmod +x /tmp/anytls-ubuntu.sh && sudo bash /tmp/anytls-ubuntu.sh update
```

新核心校验或启动失败时会自动回滚，原配置和用户不会被覆盖。

## 文件位置

| 文件 | 用途 |
|---|---|
| `/usr/local/bin/sing-box-anytls` | sing-box 服务端核心 |
| `/etc/anytls-singbox/config.json` | sing-box AnyTLS 配置 |
| `/etc/anytls-singbox/state.env` | 脚本状态 |
| `/etc/anytls-singbox/users.json` | AnyTLS 用户 |
| `/etc/anytls-singbox/padding.json` | Padding Scheme |
| `/etc/anytls-singbox/cert/` | 服务使用的证书 |
| `/etc/systemd/system/anytls-singbox.service` | systemd 服务 |

## 多系统轻量版

Debian、CentOS/RHEL、Rocky Linux、AlmaLinux 和 Fedora 也可以使用官方 `anytls-go` reference server 版：

```bash
wget -O anytls.sh --https-only https://raw.githubusercontent.com/cc63/anytls-one-click/main/anytls.sh && chmod +x anytls.sh && ./anytls.sh
```

该版不支持外部证书，客户端需要开启 `insecure` / `skip-cert-verify`。

## 上游项目

- [SagerNet/sing-box](https://github.com/SagerNet/sing-box)
- [anytls/anytls-go](https://github.com/anytls/anytls-go)
- [certbot/certbot](https://github.com/certbot/certbot)

> 仅用于合法的网络管理、隐私保护与安全测试。使用者应遵守所在地法律、服务商条款及网络管理规定。
