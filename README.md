# AnyTLS 一键搭建与管理脚本

新手推荐使用 `anytls-ubuntu.sh`，支持 Ubuntu 20.04/22.04/24.04 及更新版本，支持 `amd64` 和 `arm64`。

## 运行脚本

在 Ubuntu VPS 的 `root` 终端执行：

```bash
apt-get update && apt-get install -y curl && curl -LfsS https://raw.githubusercontent.com/cc63/anytls-one-click/main/anytls-ubuntu.sh -o /tmp/anytls-ubuntu.sh && chmod +x /tmp/anytls-ubuntu.sh && bash /tmp/anytls-ubuntu.sh
```

非 `root` 用户执行：

```bash
sudo apt-get update && sudo apt-get install -y curl && curl -LfsS https://raw.githubusercontent.com/cc63/anytls-one-click/main/anytls-ubuntu.sh -o /tmp/anytls-ubuntu.sh && chmod +x /tmp/anytls-ubuntu.sh && sudo bash /tmp/anytls-ubuntu.sh
```

执行后会显示操作菜单：

```text
1) 安装/重新安装（推荐值可一路回车）
2) 更新 sing-box 核心
3) 证书管理
4) 用户管理
5) 修改基础配置
6) Padding Scheme
7) 查看客户端配置
8) 服务管理
9) 查看状态
10) 实时日志
11) 网络优化 BBR
12) 卸载
```

## 纯 IP 安装（推荐）

在主菜单输入 `1`，然后安装方式直接回车。后面每一项都已生成推荐默认值，不想自定义时可以一路回车：

```text
安装方式 [纯IP]:       回车
监听端口 [随机端口]:  回车
用户名 [default]:          回车
密码 [自动生成]:          回车
日志级别 [info]:          回车
```

纯 IP 模式不需要域名或邮箱。脚本会自动：

- 检测 VPS 公网 IPv4，没有 IPv4 时使用 IPv6
- 在 `10000-65535` 中生成一个未被占用的随机 TCP 端口
- 生成 48 位随机密码和自签 TLS 证书
- 安装并启动最新稳定版 sing-box AnyTLS
- 应用官方 Padding Scheme、低权限用户和 systemd 开机自启
- UFW 已启用时自动放行选定端口
- 输出 AnyTLS 分享链接、sing-box JSON 和 Mihomo YAML

安装完成后，复制最后显示的 `anytls://...` 链接即可。纯 IP 使用自签证书，导出配置会自动开启 `insecure` / `skip-cert-verify`。

> 请在云厂商控制台的安全组中放行安装结果显示的 TCP 端口。云安全组不在 VPS 系统内，脚本无法代为修改。

## 域名证书安装

在主菜单选择 `1`，安装方式选择 `2`。端口、用户名、密码和日志仍可以直接回车使用默认值，只有域名必须填写，邮箱可留空。

需要提前准备：

1. 域名 A/AAAA 记录已指向 VPS。
2. Cloudflare 关闭代理小云朵，设为 `DNS only`。
3. 安全组放行 `80/TCP` 和选定的 AnyTLS 端口。
4. `80/TCP` 没有被 Nginx/Apache 占用。

Certbot 定时器会自动续期，续期成功后自动更新 AnyTLS 证书并重启服务。

## 其他功能

- 自签证书、导入已有证书、Let's Encrypt 申请和续期测试
- 多用户添加、删除和密码重置
- 端口、连接地址、日志级别和 Padding Scheme 管理
- 最新稳定版核心更新、SHA-256 校验和启动失败回滚
- 启动、停止、重启、状态、实时日志和卸载
- 可选启用 BBR、FQ 和 TCP Fast Open

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
