#!/usr/bin/env bash

set -Eeuo pipefail
umask 027

((BASH_VERSINFO[0] >= 4)) || {
    printf '需要 Bash 4.0 或更高版本。\n' >&2
    exit 1
}

SCRIPT_VERSION="2.1.0"
PROJECT_URL="https://github.com/cc63/anytls-one-click"
SING_BOX_REPO="SagerNet/sing-box"
SING_BOX_API="https://api.github.com/repos/${SING_BOX_REPO}/releases/latest"

SERVICE_NAME="anytls-singbox"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SERVICE_USER="anytls"
SERVICE_GROUP="anytls"
BIN_PATH="/usr/local/bin/sing-box-anytls"
LIB_DIR="/usr/local/lib/sing-box-anytls"
CONFIG_DIR="/etc/anytls-singbox"
CONFIG_FILE="${CONFIG_DIR}/config.json"
STATE_FILE="${CONFIG_DIR}/state.env"
USERS_FILE="${CONFIG_DIR}/users.json"
PADDING_FILE="${CONFIG_DIR}/padding.json"
CERT_DIR="${CONFIG_DIR}/cert"
CERT_FILE="${CERT_DIR}/fullchain.pem"
KEY_FILE="${CERT_DIR}/privkey.pem"
VERSION_FILE="${CONFIG_DIR}/version"
CERTBOT_HOOK="/etc/letsencrypt/renewal-hooks/deploy/anytls-singbox.sh"
SYSCTL_FILE="/etc/sysctl.d/99-anytls-singbox.conf"

if [[ -t 1 ]]; then
    C_RED='\033[31m'
    C_GREEN='\033[32m'
    C_YELLOW='\033[33m'
    C_BLUE='\033[36m'
    C_RESET='\033[0m'
else
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_RESET=''
fi

info() { printf '%b\n' "${C_GREEN}[信息]${C_RESET} $*"; }
warn() { printf '%b\n' "${C_YELLOW}[提示]${C_RESET} $*"; }
error() { printf '%b\n' "${C_RED}[错误]${C_RESET} $*" >&2; }
die() { error "$*"; exit 1; }
title() { printf '\n%b\n' "${C_BLUE}==== $* ====${C_RESET}"; }

TEMP_ROOT="$(mktemp -d)"
new_temp_dir() {
    mktemp -d "${TEMP_ROOT}/work.XXXXXX"
}

cleanup_temp() {
    if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" && "$TEMP_ROOT" == /tmp/* ]]; then
        rm -rf -- "$TEMP_ROOT"
    fi
}
trap cleanup_temp EXIT

pause_menu() {
    [[ -t 0 ]] || return 0
    read -r -p "按回车键继续..." _
}

confirm() {
    local prompt="$1" answer
    read -r -p "${prompt} [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

check_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：sudo bash $0"
}

check_system() {
    [[ -r /etc/os-release ]] || die "无法识别操作系统。"
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || die "此脚本仅支持 Ubuntu，当前系统：${PRETTY_NAME:-unknown}"
    dpkg --compare-versions "${VERSION_ID:-0}" ge "20.04" || die "仅支持 Ubuntu 20.04 及更新版本。"
    command -v systemctl >/dev/null 2>&1 || die "未检测到 systemd。"
    info "已检测到 ${PRETTY_NAME:-Ubuntu}"
}

apt_install() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends "$@"
}

install_dependencies() {
    local packages=(ca-certificates curl jq openssl tar gzip iproute2 passwd)
    local missing=() package
    for package in "${packages[@]}"; do
        dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' || missing+=("$package")
    done
    if ((${#missing[@]})); then
        info "正在安装依赖：${missing[*]}"
        apt_install "${missing[@]}"
    fi
}

install_certbot() {
    if ! command -v certbot >/dev/null 2>&1; then
        info "正在安装 Ubuntu 软件源中的 Certbot..."
        apt_install certbot
    fi
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
}

detect_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) printf 'amd64\n' ;;
        aarch64 | arm64) printf 'arm64\n' ;;
        *) die "仅支持 amd64/x86_64 和 arm64/aarch64，当前架构：$(uname -m)" ;;
    esac
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

validate_domain() {
    local domain="${1,,}"
    ((${#domain} <= 253)) || return 1
    [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

validate_ipv4() {
    local address="$1" octet
    local -a octets
    [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octets <<<"$address"
    for octet in "${octets[@]}"; do
        ((10#$octet <= 255)) || return 1
    done
}

validate_sni() {
    validate_domain "$1" || validate_ipv4 "$1"
}

validate_server_address() {
    validate_domain "$1" || validate_ipv4 "$1" || [[ "$1" =~ ^[0-9A-Fa-f:]+$ && "$1" == *:* ]]
}

validate_username() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]{1,32}$ ]]
}

validate_password() {
    [[ "$1" =~ ^[A-Za-z0-9._~-]{8,128}$ ]]
}

validate_log_level() {
    [[ "$1" =~ ^(debug|info|warn|error)$ ]]
}

random_password() {
    openssl rand -hex 24
}

port_is_listening() {
    local port="$1"
    ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|\]|:)$port$"
}

show_port_owner() {
    local port="$1"
    ss -ltnp 2>/dev/null | awk -v suffix=":${port}" 'NR == 1 || $4 ~ suffix"$"'
}

get_public_ipv4() {
    local endpoint address
    for endpoint in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
        address="$(curl -4 -fsS --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
        if validate_ipv4 "$address"; then
            printf '%s\n' "$address"
            return 0
        fi
    done
    return 0
}

get_public_ipv6() {
    local endpoint address
    for endpoint in https://api64.ipify.org https://ifconfig.co/ip https://ipv6.icanhazip.com; do
        address="$(curl -6 -fsS --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ "$address" =~ ^[0-9A-Fa-f:]+$ && "$address" == *:* ]]; then
            printf '%s\n' "$address"
            return 0
        fi
    done
    return 0
}

default_server_address() {
    local address
    address="$(get_public_ipv4)"
    [[ -n "$address" ]] || address="$(get_public_ipv6)"
    printf '%s\n' "$address"
}

check_domain_dns() {
    local domain="$1" public4 public6 addresses4 addresses6 matched=false
    public4="$(get_public_ipv4)"
    public6="$(get_public_ipv6)"
    addresses4="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    addresses6="$(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)"

    [[ -n "$addresses4$addresses6" ]] || die "域名 ${domain} 尚未解析，请先添加 A/AAAA 记录。"
    if [[ -n "$public4" ]] && grep -Fxq "$public4" <<<"$addresses4"; then
        matched=true
    fi
    if [[ -n "$public6" ]] && grep -Fxq "$public6" <<<"$addresses6"; then
        matched=true
    fi

    info "本机公网 IPv4：${public4:-未检测到}"
    [[ -z "$public6" ]] || info "本机公网 IPv6：${public6}"
    info "${domain} 解析结果：$(tr '\n' ' ' <<<"$addresses4$addresses6")"

    if [[ "$matched" != true ]]; then
        warn "域名解析未与脚本检测到的公网 IP 匹配。"
        warn "若使用 Cloudflare，请先关闭代理小云朵，改为 DNS only。"
        confirm "确定已做端口映射并继续申请吗？" || die "已取消证书申请。"
    fi

    if [[ -n "$addresses6" ]] && { [[ -z "$public6" ]] || ! grep -Fxq "$public6" <<<"$addresses6"; }; then
        warn "域名存在不指向本机的 AAAA 记录，Let's Encrypt 验证可能失败。"
        confirm "仍然继续吗？" || die "请删除错误的 AAAA 记录后重试。"
    fi
}

create_service_user() {
    getent group "$SERVICE_GROUP" >/dev/null 2>&1 || groupadd --system "$SERVICE_GROUP"
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        useradd --system --gid "$SERVICE_GROUP" --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"
    fi
}

ensure_layout() {
    create_service_user
    install -d -m 0750 -o root -g "$SERVICE_GROUP" "$CONFIG_DIR" "$CERT_DIR"
    install -d -m 0755 -o root -g root "$LIB_DIR"
}

write_default_padding() {
    local target="$PADDING_FILE"
    jq -n '[
        "stop=8",
        "0=30-30",
        "1=100-400",
        "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000",
        "3=9-9,500-1000",
        "4=500-1000",
        "5=500-1000",
        "6=500-1000",
        "7=500-1000"
    ]' >"$target"
    chown root:"$SERVICE_GROUP" "$target"
    chmod 0640 "$target"
}

init_users() {
    local username="$1" password="$2"
    jq -n --arg name "$username" --arg password "$password" '[{name: $name, password: $password}]' >"$USERS_FILE"
    chown root:"$SERVICE_GROUP" "$USERS_FILE"
    chmod 0640 "$USERS_FILE"
}

SERVER_ADDR=""
SNI=""
PORT="443"
LOG_LEVEL="info"
CERT_MODE="selfsigned"
CERTBOT_NAME=""
EMAIL=""
INSECURE="true"
MANAGED_UFW_PORT=""
MANAGED_UFW_80="false"

load_state() {
    [[ -r "$STATE_FILE" ]] || return 1
    # STATE_FILE 只能由 root 写入。
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    validate_port "$PORT" || die "状态文件中的端口无效。"
    PORT="$((10#$PORT))"
    validate_sni "$SNI" || die "状态文件中的 SNI 无效。"
    validate_server_address "$SERVER_ADDR" || die "状态文件中的服务器地址无效。"
    validate_log_level "$LOG_LEVEL" || die "状态文件中的日志级别无效。"
    [[ "$CERT_MODE" =~ ^(letsencrypt|custom|selfsigned)$ ]] || die "状态文件中的证书模式无效。"
    [[ "$INSECURE" =~ ^(true|false)$ ]] || die "状态文件中的证书验证选项无效。"
    [[ "$CERT_MODE" != "letsencrypt" ]] || validate_domain "$CERTBOT_NAME" || die "状态文件中的 Certbot 名称无效。"
}

save_state() {
    local tmp
    tmp="$(mktemp "${CONFIG_DIR}/.state.XXXXXX")"
    {
        printf 'SERVER_ADDR=%q\n' "$SERVER_ADDR"
        printf 'SNI=%q\n' "$SNI"
        printf 'PORT=%q\n' "$PORT"
        printf 'LOG_LEVEL=%q\n' "$LOG_LEVEL"
        printf 'CERT_MODE=%q\n' "$CERT_MODE"
        printf 'CERTBOT_NAME=%q\n' "$CERTBOT_NAME"
        printf 'EMAIL=%q\n' "$EMAIL"
        printf 'INSECURE=%q\n' "$INSECURE"
        printf 'MANAGED_UFW_PORT=%q\n' "$MANAGED_UFW_PORT"
        printf 'MANAGED_UFW_80=%q\n' "$MANAGED_UFW_80"
    } >"$tmp"
    install -m 0640 -o root -g "$SERVICE_GROUP" "$tmp" "$STATE_FILE"
    rm -f -- "$tmp"
}

render_config() {
    local target="$1"
    jq -n \
        --arg log_level "$LOG_LEVEL" \
        --argjson port "$PORT" \
        --arg cert "$CERT_FILE" \
        --arg key "$KEY_FILE" \
        --slurpfile users "$USERS_FILE" \
        --slurpfile padding "$PADDING_FILE" \
        '{
            log: {level: $log_level, timestamp: true},
            inbounds: [{
                type: "anytls",
                tag: "anytls-in",
                listen: "::",
                listen_port: $port,
                users: $users[0],
                padding_scheme: $padding[0],
                tls: {
                    enabled: true,
                    alpn: ["h2", "http/1.1"],
                    certificate_path: $cert,
                    key_path: $key
                }
            }]
        }' >"$target"
}

validate_data_files() {
    jq -e 'type == "array" and length > 0 and all(.[]; (.name | type == "string" and length > 0) and (.password | type == "string" and length > 0))' "$USERS_FILE" >/dev/null || {
        error "用户配置无效。"
        return 1
    }
    jq -e 'type == "array" and length > 0 and all(.[]; type == "string")' "$PADDING_FILE" >/dev/null || {
        error "Padding Scheme 无效。"
        return 1
    }
}

write_config() {
    local tmp
    validate_data_files || return 1
    tmp="$(mktemp "${CONFIG_DIR}/.config.XXXXXX")"
    render_config "$tmp"
    "$BIN_PATH" check -c "$tmp" >/dev/null || {
        rm -f -- "$tmp"
        error "sing-box 配置校验失败。"
        return 1
    }
    install -m 0640 -o root -g "$SERVICE_GROUP" "$tmp" "$CONFIG_FILE"
    rm -f -- "$tmp"
}

write_service() {
    local tmp
    tmp="$(mktemp)"
    cat >"$tmp" <<EOF
[Unit]
Description=AnyTLS Server powered by sing-box
Documentation=${PROJECT_URL}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStartPre=${BIN_PATH} check -c ${CONFIG_FILE}
ExecStart=${BIN_PATH} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
Environment=LD_LIBRARY_PATH=${LIB_DIR}
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
    install -m 0644 -o root -g root "$tmp" "$SERVICE_FILE"
    rm -f -- "$tmp"
    systemctl daemon-reload
}

RELEASE_VERSION=""
RELEASE_URL=""
RELEASE_SHA256=""

get_latest_release() {
    local arch json tag asset digest
    arch="$(detect_arch)"
    json="$(curl -fsSL --retry 3 --connect-timeout 10 "$SING_BOX_API")" || die "无法获取 sing-box 最新版本。"
    tag="$(jq -r '.tag_name // empty' <<<"$json")"
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || die "GitHub Release 版本号无效。"
    RELEASE_VERSION="${tag#v}"
    asset="sing-box-${RELEASE_VERSION}-linux-${arch}.tar.gz"
    RELEASE_URL="$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$json")"
    digest="$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .digest // empty' <<<"$json")"
    [[ -n "$RELEASE_URL" ]] || die "未找到适用于 ${arch} 的 sing-box Release。"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "GitHub Release 未提供可验证的 SHA-256 摘要。"
    RELEASE_SHA256="${digest#sha256:}"
    dpkg --compare-versions "$RELEASE_VERSION" ge "1.12.0" || die "AnyTLS 需要 sing-box 1.12.0 或更高版本。"
}

PREPARED_BIN=""
PREPARED_LIB=""

prepare_release() {
    local work archive actual extracted
    get_latest_release
    work="$(new_temp_dir)"
    archive="${work}/sing-box.tar.gz"
    info "正在下载 sing-box ${RELEASE_VERSION}..."
    curl -fL --retry 3 --connect-timeout 10 "$RELEASE_URL" -o "$archive"
    actual="$(sha256sum "$archive" | awk '{print $1}')"
    [[ "$actual" == "$RELEASE_SHA256" ]] || die "sing-box 安装包 SHA-256 校验失败。"
    tar -xzf "$archive" -C "$work"
    extracted="$(find "$work" -mindepth 2 -maxdepth 2 -type f -name sing-box -print -quit)"
    [[ -n "$extracted" && -x "$extracted" ]] || die "sing-box 安装包内未找到可执行文件。"
    "$extracted" version >/dev/null || die "sing-box 可执行文件验证失败。"
    PREPARED_BIN="$extracted"
    PREPARED_LIB="$(dirname "$extracted")/libcronet.so"
}

install_prepared_release() {
    install -m 0755 -o root -g root "$PREPARED_BIN" "$BIN_PATH"
    if [[ -f "$PREPARED_LIB" ]]; then
        install -m 0755 -o root -g root "$PREPARED_LIB" "${LIB_DIR}/libcronet.so"
    fi
    printf '%s\n' "$RELEASE_VERSION" >"$VERSION_FILE"
    chown root:"$SERVICE_GROUP" "$VERSION_FILE"
    chmod 0640 "$VERSION_FILE"
}

installed_version() {
    if [[ -x "$BIN_PATH" ]]; then
        "$BIN_PATH" version 2>/dev/null | awk 'NR == 1 {print $3}'
    fi
}

is_installed() {
    [[ -x "$BIN_PATH" && -f "$CONFIG_FILE" && -f "$STATE_FILE" && -f "$SERVICE_FILE" ]]
}

require_installed() {
    is_installed || die "AnyTLS Ubuntu 版尚未安装，请先执行：bash $0 install"
    load_state
}

certificate_key_matches() {
    local cert="$1" key="$2" cert_hash key_hash
    cert_hash="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')" || return 1
    key_hash="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')" || return 1
    [[ -n "$cert_hash" && "$cert_hash" == "$key_hash" ]]
}

install_certificate_files() {
    local cert="$1" key="$2"
    openssl x509 -in "$cert" -noout >/dev/null 2>&1 || die "证书文件无效：${cert}"
    openssl pkey -in "$key" -noout >/dev/null 2>&1 || die "私钥文件无效：${key}"
    certificate_key_matches "$cert" "$key" || die "证书与私钥不匹配。"
    openssl x509 -checkend 0 -noout -in "$cert" >/dev/null || die "证书已过期。"
    install -m 0640 -o root -g "$SERVICE_GROUP" "$cert" "$CERT_FILE"
    install -m 0640 -o root -g "$SERVICE_GROUP" "$key" "$KEY_FILE"
}

generate_self_signed_certificate() {
    local sni="$1" work config san_type
    work="$(new_temp_dir)"
    config="${work}/openssl.cnf"
    if validate_ipv4 "$sni"; then
        san_type="IP"
    else
        san_type="DNS"
    fi
    cat >"$config" <<EOF
[req]
distinguished_name=req_distinguished_name
x509_extensions=v3_req
prompt=no
[req_distinguished_name]
CN=${sni}
[v3_req]
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${san_type}:${sni}
EOF
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
        -config "$config" -keyout "${work}/privkey.pem" -out "${work}/fullchain.pem" >/dev/null 2>&1 || die "生成自签证书失败。"
    install_certificate_files "${work}/fullchain.pem" "${work}/privkey.pem"
}

copy_certbot_certificate() {
    local lineage="/etc/letsencrypt/live/${CERTBOT_NAME}"
    [[ -r "${lineage}/fullchain.pem" && -r "${lineage}/privkey.pem" ]] || die "找不到 Certbot 证书：${lineage}"
    install_certificate_files "${lineage}/fullchain.pem" "${lineage}/privkey.pem"
}

write_certbot_hook() {
    install -d -m 0755 -o root -g root "$(dirname "$CERTBOT_HOOK")"
    local tmp
    tmp="$(mktemp)"
    cat >"$tmp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

STATE_FILE="/etc/anytls-singbox/state.env"
[[ -r "$STATE_FILE" ]] || exit 0
# shellcheck disable=SC1090
. "$STATE_FILE"
[[ "${CERT_MODE:-}" == "letsencrypt" && -n "${CERTBOT_NAME:-}" ]] || exit 0
lineage="/etc/letsencrypt/live/${CERTBOT_NAME}"
if [[ -n "${RENEWED_LINEAGE:-}" && "$RENEWED_LINEAGE" != "$lineage" ]]; then
    exit 0
fi
[[ -r "${lineage}/fullchain.pem" && -r "${lineage}/privkey.pem" ]] || exit 1
install -m 0640 -o root -g anytls "${lineage}/fullchain.pem" /etc/anytls-singbox/cert/fullchain.pem
install -m 0640 -o root -g anytls "${lineage}/privkey.pem" /etc/anytls-singbox/cert/privkey.pem
systemctl try-restart anytls-singbox.service
EOF
    install -m 0755 -o root -g root "$tmp" "$CERTBOT_HOOK"
    rm -f -- "$tmp"
}

issue_letsencrypt_certificate() {
    local domain="$1" email="$2" email_args=() opened_ufw=false
    validate_domain "$domain" || die "域名格式无效。"
    check_domain_dns "$domain"
    if port_is_listening 80; then
        error "80/TCP 已被占用，Certbot standalone 无法启动。"
        show_port_owner 80
        die "请先停止占用 80 端口的程序后重试。"
    fi
    install_certbot
    if open_ufw_port 80; then
        MANAGED_UFW_80="true"
        opened_ufw=true
    fi
    if [[ -n "$email" ]]; then
        email_args=(--email "$email")
    else
        email_args=(--register-unsafely-without-email)
    fi
    info "正在为 ${domain} 申请 Let's Encrypt 证书..."
    if ! certbot certonly --standalone --preferred-challenges http \
        --non-interactive --agree-tos --keep-until-expiring \
        --cert-name "$domain" -d "$domain" "${email_args[@]}"; then
        if [[ "$opened_ufw" == "true" ]]; then
            remove_ufw_port 80
            MANAGED_UFW_80="false"
        fi
        die "Let's Encrypt 证书申请失败，请根据 Certbot 日志修正 DNS/端口后重试。"
    fi
    CERTBOT_NAME="$domain"
    copy_certbot_certificate
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
}

configure_certificate_interactive() {
    local choice domain email cert key sni address skip
    title "证书模式"
    printf '1) 我有域名，自动申请 Let\x27s Encrypt 证书\n'
    printf '2) 我有现成证书和私钥（高级）\n'
    printf '3) 我没有域名，生成自签证书\n'
    read -r -p "请选择 [1-3]，直接回车选 1: " choice
    choice="${choice:-1}"
    case "$choice" in
        1)
            read -r -p "请输入已解析到本机的域名: " domain
            validate_domain "$domain" || die "域名格式无效。"
            read -r -p "请输入 ACME 邮箱（可留空）: " email
            issue_letsencrypt_certificate "${domain,,}" "$email"
            CERT_MODE="letsencrypt"
            SNI="${domain,,}"
            SERVER_ADDR="${domain,,}"
            EMAIL="$email"
            INSECURE="false"
            ;;
        2)
            read -r -p "证书 fullchain.pem/.crt 完整路径: " cert
            read -r -p "私钥 privkey.pem/.key 完整路径: " key
            [[ -f "$cert" && -f "$key" ]] || die "证书或私钥文件不存在。"
            read -r -p "证书对应的域名/SNI: " sni
            validate_sni "$sni" || die "SNI 格式无效。"
            address="$(default_server_address)"
            read -r -p "客户端连接地址 [${address}]: " SERVER_ADDR
            SERVER_ADDR="${SERVER_ADDR:-$address}"
            [[ -n "$SERVER_ADDR" ]] || die "无法检测公网 IP，请手动输入连接地址。"
            validate_server_address "$SERVER_ADDR" || die "客户端连接地址格式无效。"
            skip="n"
            read -r -p "该证书是自签/Cloudflare Origin 证书吗？ [y/N]: " skip
            install_certificate_files "$cert" "$key"
            CERT_MODE="custom"
            CERTBOT_NAME=""
            EMAIL=""
            SNI="$sni"
            [[ "$skip" =~ ^[Yy]$ ]] && INSECURE="true" || INSECURE="false"
            ;;
        3)
            address="$(default_server_address)"
            read -r -p "请输入证书 SNI [www.microsoft.com]: " sni
            sni="${sni:-www.microsoft.com}"
            validate_sni "$sni" || die "SNI 格式无效。"
            read -r -p "客户端连接地址 [${address}]: " SERVER_ADDR
            SERVER_ADDR="${SERVER_ADDR:-$address}"
            [[ -n "$SERVER_ADDR" ]] || die "无法检测公网 IP，请手动输入连接地址。"
            validate_server_address "$SERVER_ADDR" || die "客户端连接地址格式无效。"
            generate_self_signed_certificate "$sni"
            CERT_MODE="selfsigned"
            CERTBOT_NAME=""
            EMAIL=""
            SNI="$sni"
            INSECURE="true"
            ;;
        *) die "无效选项。" ;;
    esac
}

ufw_is_active() {
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -n 1 | grep -q 'Status: active'
}

open_ufw_port() {
    local port="$1"
    ufw_is_active || return 1
    if ufw status | awk '{print $1}' | grep -Eq "^${port}(/tcp)?$"; then
        return 1
    fi
    ufw allow "${port}/tcp" comment 'AnyTLS Ubuntu' >/dev/null
    info "已在 UFW 放行 ${port}/TCP。"
    return 0
}

remove_ufw_port() {
    local port="$1"
    [[ -n "$port" ]] || return 0
    ufw_is_active || return 0
    ufw --force delete allow "${port}/tcp" >/dev/null 2>&1 || true
}

sync_firewall() {
    local old_managed_port="${MANAGED_UFW_PORT:-}"
    if [[ -n "$old_managed_port" && "$old_managed_port" != "$PORT" ]]; then
        remove_ufw_port "$old_managed_port"
        MANAGED_UFW_PORT=""
    fi
    if [[ -z "$MANAGED_UFW_PORT" ]] && open_ufw_port "$PORT"; then
        MANAGED_UFW_PORT="$PORT"
    fi
    if [[ "$CERT_MODE" == "letsencrypt" ]]; then
        if [[ "$MANAGED_UFW_80" != "true" ]] && open_ufw_port 80; then
            MANAGED_UFW_80="true"
        fi
    elif [[ "$MANAGED_UFW_80" == "true" ]]; then
        remove_ufw_port 80
        MANAGED_UFW_80="false"
    fi
    save_state
}

service_healthy() {
    local attempts=0
    while ((attempts < 15)); do
        systemctl is-active --quiet "$SERVICE_NAME" && return 0
        sleep 1
        ((attempts += 1))
    done
    return 1
}

restart_and_verify() {
    systemctl restart "$SERVICE_NAME"
    if ! service_healthy; then
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager >&2 || true
        return 1
    fi
}

prompt_install_config() {
    local input username password
    read -r -p "AnyTLS 监听端口 [443]: " input
    PORT="${input:-443}"
    validate_port "$PORT" || die "端口必须为 1-65535 的整数。"
    PORT="$((10#$PORT))"
    [[ "$PORT" != "80" ]] || die "80 端口需要保留给证书申请与续期。"
    if port_is_listening "$PORT"; then
        error "${PORT}/TCP 已被占用。"
        show_port_owner "$PORT"
        die "请更换端口或停止占用程序。"
    fi
    read -r -p "初始用户名 [default]: " username
    username="${username:-default}"
    validate_username "$username" || die "用户名仅能包含字母、数字、点、下划线和减号。"
    read -r -p "初始密码（留空随机生成）: " password
    password="${password:-$(random_password)}"
    validate_password "$password" || die "密码需为 8-128 位，仅允许字母、数字和 . _ ~ -。"
    read -r -p "日志级别 [info]: " input
    LOG_LEVEL="${input:-info}"
    validate_log_level "$LOG_LEVEL" || die "日志级别只能是 debug/info/warn/error。"
    init_users "$username" "$password"
}

select_available_default_port() {
    local candidate attempt
    local -a preferred_ports=(443 8443 2053 2083 2087 2096 9443)
    for candidate in "${preferred_ports[@]}"; do
        if ! port_is_listening "$candidate"; then
            PORT="$candidate"
            if [[ "$PORT" != "443" ]]; then
                warn "443/TCP 已被其他程序占用，已自动改用 ${PORT}/TCP。"
            fi
            return 0
        fi
    done
    for ((attempt = 0; attempt < 30; attempt++)); do
        candidate="$((10000 + RANDOM))"
        if ! port_is_listening "$candidate"; then
            PORT="$candidate"
            warn "常用端口均被占用，已自动选择 ${PORT}/TCP。"
            return 0
        fi
    done
    die "无法找到可用 TCP 端口，请先停止不需要的服务。"
}

init_quick_defaults() {
    select_available_default_port
    LOG_LEVEL="info"
    init_users "default" "$(random_password)"
}

configure_quick_ip() {
    init_quick_defaults
    SERVER_ADDR="$(default_server_address)"
    [[ -n "$SERVER_ADDR" ]] || die "未能自动检测公网 IP，请改用交互菜单中的高级安装。"
    validate_server_address "$SERVER_ADDR" || die "检测到的公网 IP 格式无效。"
    SNI="www.microsoft.com"
    CERT_MODE="selfsigned"
    CERTBOT_NAME=""
    EMAIL=""
    INSECURE="true"
    generate_self_signed_certificate "$SNI"
    info "已选择纯 IP 模式：${SERVER_ADDR}:${PORT}，不需要域名。"
}

configure_quick_domain() {
    local domain="${1:-}" email="${2:-}"
    init_quick_defaults
    if [[ -z "$domain" ]]; then
        [[ -t 0 ]] || die "请在 install-domain 后填写域名。"
        read -r -p "请输入已解析到这台 VPS 的域名: " domain
    fi
    domain="${domain,,}"
    validate_domain "$domain" || die "域名格式不正确，例如 anytls.example.com。"
    if [[ -z "$email" && -t 0 ]]; then
        read -r -p "证书到期提醒邮箱（可直接回车跳过）: " email
    fi
    issue_letsencrypt_certificate "$domain" "$email"
    CERT_MODE="letsencrypt"
    SNI="$domain"
    SERVER_ADDR="$domain"
    EMAIL="$email"
    INSECURE="false"
}

SELECTED_INSTALL_MODE=""

choose_install_mode() {
    local choice
    title "选择安装方式"
    printf '1) 纯 IP 极速安装（推荐，不需要域名，全部自动）\n'
    printf '2) 域名证书安装（只需输入域名）\n'
    printf '3) 高级自定义安装\n'
    read -r -p "请选择 [1-3]，直接回车默认选 1: " choice
    case "${choice:-1}" in
        1) SELECTED_INSTALL_MODE="ip" ;;
        2) SELECTED_INSTALL_MODE="domain" ;;
        3) SELECTED_INSTALL_MODE="advanced" ;;
        *) die "请输入 1、2 或 3。" ;;
    esac
}

install_anytls() {
    local mode="${1:-select}" domain="${2:-}" email="${3:-}"
    title "安装 AnyTLS Ubuntu 版"
    if is_installed; then
        confirm "已检测到安装，要重新安装吗？" || return 0
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    fi
    install_dependencies
    ensure_layout
    if [[ "$mode" == "select" ]]; then
        choose_install_mode
        mode="$SELECTED_INSTALL_MODE"
    fi
    case "$mode" in
        ip) configure_quick_ip ;;
        domain) configure_quick_domain "$domain" "$email" ;;
        advanced)
            prompt_install_config
            configure_certificate_interactive
            ;;
        *) die "未知安装模式：${mode}" ;;
    esac
    prepare_release
    install_prepared_release
    write_default_padding
    save_state
    [[ "$CERT_MODE" == "letsencrypt" ]] && write_certbot_hook
    write_config
    write_service
    sync_firewall
    systemctl enable "$SERVICE_NAME" >/dev/null
    restart_and_verify || die "AnyTLS 服务启动失败，请查看上方日志。"
    title "安装完成"
    info "AnyTLS 已启动，sing-box 版本 ${RELEASE_VERSION}。"
    warn "请同时在云厂商安全组放行 ${PORT}/TCP$([[ "$CERT_MODE" == "letsencrypt" ]] && printf '和 80/TCP')。"
    show_config
}

update_anytls() {
    require_installed
    install_dependencies
    local current backup_dir
    current="$(installed_version)"
    prepare_release
    if [[ "$current" == "$RELEASE_VERSION" ]]; then
        info "当前已是最新稳定版 sing-box ${current}。"
        return 0
    fi
    backup_dir="$(new_temp_dir)"
    cp -a "$BIN_PATH" "${backup_dir}/sing-box"
    [[ -f "${LIB_DIR}/libcronet.so" ]] && cp -a "${LIB_DIR}/libcronet.so" "${backup_dir}/libcronet.so"
    install_prepared_release
    if ! "$BIN_PATH" check -c "$CONFIG_FILE" >/dev/null || ! restart_and_verify; then
        error "新版本启动失败，正在回滚..."
        install -m 0755 -o root -g root "${backup_dir}/sing-box" "$BIN_PATH"
        [[ -f "${backup_dir}/libcronet.so" ]] && install -m 0755 -o root -g root "${backup_dir}/libcronet.so" "${LIB_DIR}/libcronet.so"
        printf '%s\n' "$current" >"$VERSION_FILE"
        restart_and_verify || true
        die "已回滚到 sing-box ${current}。"
    fi
    info "sing-box 已从 ${current:-unknown} 更新到 ${RELEASE_VERSION}。"
}

renew_certificate() {
    require_installed
    [[ "$CERT_MODE" == "letsencrypt" ]] || die "当前不是 Let's Encrypt 证书模式。"
    install_certbot
    certbot renew --cert-name "$CERTBOT_NAME"
    copy_certbot_certificate
    restart_and_verify || die "证书更新后服务启动失败。"
    info "证书检查/续期完成。"
}

test_certificate_renewal() {
    require_installed
    [[ "$CERT_MODE" == "letsencrypt" ]] || die "当前不是 Let's Encrypt 证书模式。"
    install_certbot
    certbot renew --dry-run --cert-name "$CERTBOT_NAME"
}

change_certificate() {
    require_installed
    local old_mode="$CERT_MODE" old_name="$CERTBOT_NAME" backup_dir
    backup_dir="$(new_temp_dir)"
    cp -a "$STATE_FILE" "${backup_dir}/state.env"
    cp -a "$CERT_FILE" "${backup_dir}/fullchain.pem"
    cp -a "$KEY_FILE" "${backup_dir}/privkey.pem"
    cp -a "$CONFIG_FILE" "${backup_dir}/config.json"
    [[ -f "$CERTBOT_HOOK" ]] && cp -a "$CERTBOT_HOOK" "${backup_dir}/hook.sh"
    configure_certificate_interactive
    save_state
    if [[ "$CERT_MODE" == "letsencrypt" ]]; then
        write_certbot_hook
    elif [[ -f "$CERTBOT_HOOK" ]]; then
        rm -f -- "$CERTBOT_HOOK"
    fi
    if ! write_config || ! restart_and_verify; then
        error "新证书配置启动失败，正在回滚..."
        install -m 0640 -o root -g "$SERVICE_GROUP" "${backup_dir}/state.env" "$STATE_FILE"
        install -m 0640 -o root -g "$SERVICE_GROUP" "${backup_dir}/fullchain.pem" "$CERT_FILE"
        install -m 0640 -o root -g "$SERVICE_GROUP" "${backup_dir}/privkey.pem" "$KEY_FILE"
        install -m 0640 -o root -g "$SERVICE_GROUP" "${backup_dir}/config.json" "$CONFIG_FILE"
        if [[ -f "${backup_dir}/hook.sh" ]]; then
            install -m 0755 -o root -g root "${backup_dir}/hook.sh" "$CERTBOT_HOOK"
        else
            rm -f -- "$CERTBOT_HOOK"
        fi
        load_state
        restart_and_verify || true
        die "证书更换失败，已恢复旧配置。"
    fi
    sync_firewall
    info "证书模式已从 ${old_mode} 更换为 ${CERT_MODE}。"
    if [[ "$old_mode" == "letsencrypt" && "$old_name" != "$CERTBOT_NAME" ]]; then
        warn "旧 Certbot 证书 ${old_name} 仍保留在 /etc/letsencrypt，本脚本不会自动删除。"
    fi
}

show_certificate_status() {
    require_installed
    title "证书状态"
    printf '模式: %s\nSNI: %s\n' "$CERT_MODE" "$SNI"
    openssl x509 -in "$CERT_FILE" -noout -subject -issuer -serial -dates -ext subjectAltName 2>/dev/null || true
    if [[ "$CERT_MODE" == "letsencrypt" ]]; then
        printf '\nCertbot 定时器: %s\n' "$(systemctl is-enabled certbot.timer 2>/dev/null || true)"
        printf 'Certbot 名称: %s\n' "$CERTBOT_NAME"
    fi
}

certificate_menu() {
    require_installed
    while true; do
        title "证书管理"
        printf '1) 查看证书\n2) 更换/重新申请证书\n3) 检查并续期\n4) 测试自动续期\n0) 返回\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) show_certificate_status; pause_menu ;;
            2) change_certificate; pause_menu ;;
            3) renew_certificate; pause_menu ;;
            4) test_certificate_renewal; pause_menu ;;
            0) return ;;
            *) warn "无效选项。" ;;
        esac
    done
}

apply_users_change() {
    local backup="$1"
    if ! write_config || ! restart_and_verify; then
        install -m 0640 -o root -g "$SERVICE_GROUP" "$backup" "$USERS_FILE"
        write_config
        restart_and_verify || true
        die "用户配置应用失败，已回滚。"
    fi
}

list_users() {
    jq -r 'to_entries[] | "\(.key + 1)) \(.value.name)"' "$USERS_FILE"
}

add_user() {
    local name password tmp backup
    read -r -p "新用户名: " name
    validate_username "$name" || die "用户名格式无效。"
    jq -e --arg name "$name" 'any(.[]; .name == $name)' "$USERS_FILE" >/dev/null && die "用户 ${name} 已存在。"
    read -r -p "密码（留空随机生成）: " password
    password="${password:-$(random_password)}"
    validate_password "$password" || die "密码需为 8-128 位，仅允许字母、数字和 . _ ~ -。"
    backup="$(new_temp_dir)/users.json"
    cp -a "$USERS_FILE" "$backup"
    tmp="$(mktemp "${CONFIG_DIR}/.users.XXXXXX")"
    jq --arg name "$name" --arg password "$password" '. += [{name: $name, password: $password}]' "$USERS_FILE" >"$tmp"
    install -m 0640 -o root -g "$SERVICE_GROUP" "$tmp" "$USERS_FILE"
    rm -f -- "$tmp"
    apply_users_change "$backup"
    info "用户 ${name} 已添加。"
    show_config
}

reset_user_password() {
    local name password tmp backup
    list_users
    read -r -p "要重置密码的用户名: " name
    jq -e --arg name "$name" 'any(.[]; .name == $name)' "$USERS_FILE" >/dev/null || die "用户不存在。"
    read -r -p "新密码（留空随机生成）: " password
    password="${password:-$(random_password)}"
    validate_password "$password" || die "密码需为 8-128 位，仅允许字母、数字和 . _ ~ -。"
    backup="$(new_temp_dir)/users.json"
    cp -a "$USERS_FILE" "$backup"
    tmp="$(mktemp "${CONFIG_DIR}/.users.XXXXXX")"
    jq --arg name "$name" --arg password "$password" 'map(if .name == $name then .password = $password else . end)' "$USERS_FILE" >"$tmp"
    install -m 0640 -o root -g "$SERVICE_GROUP" "$tmp" "$USERS_FILE"
    rm -f -- "$tmp"
    apply_users_change "$backup"
    info "用户 ${name} 密码已重置。"
    show_config
}

delete_user() {
    local name tmp count backup
    count="$(jq 'length' "$USERS_FILE")"
    ((count > 1)) || die "至少必须保留一个用户。"
    list_users
    read -r -p "要删除的用户名: " name
    jq -e --arg name "$name" 'any(.[]; .name == $name)' "$USERS_FILE" >/dev/null || die "用户不存在。"
    confirm "确定删除用户 ${name} 吗？" || return 0
    backup="$(new_temp_dir)/users.json"
    cp -a "$USERS_FILE" "$backup"
    tmp="$(mktemp "${CONFIG_DIR}/.users.XXXXXX")"
    jq --arg name "$name" 'map(select(.name != $name))' "$USERS_FILE" >"$tmp"
    install -m 0640 -o root -g "$SERVICE_GROUP" "$tmp" "$USERS_FILE"
    rm -f -- "$tmp"
    apply_users_change "$backup"
    info "用户 ${name} 已删除。"
}

users_menu() {
    require_installed
    while true; do
        title "用户管理"
        list_users
        printf '\n1) 添加用户\n2) 重置密码\n3) 删除用户\n0) 返回\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) add_user; pause_menu ;;
            2) reset_user_password; pause_menu ;;
            3) delete_user; pause_menu ;;
            0) return ;;
            *) warn "无效选项。" ;;
        esac
    done
}

change_config() {
    require_installed
    local input backup_state
    backup_state="$(new_temp_dir)/state.env"
    cp -a "$STATE_FILE" "$backup_state"
    read -r -p "客户端连接地址 [${SERVER_ADDR}]: " input
    SERVER_ADDR="${input:-$SERVER_ADDR}"
    validate_server_address "$SERVER_ADDR" || die "客户端连接地址格式无效。"
    read -r -p "监听端口 [${PORT}]: " input
    input="${input:-$PORT}"
    validate_port "$input" || die "端口无效。"
    input="$((10#$input))"
    [[ "$input" != "80" ]] || die "80 端口需要保留给证书续期。"
    if [[ "$input" != "$PORT" ]] && port_is_listening "$input"; then
        show_port_owner "$input"
        die "${input}/TCP 已被占用。"
    fi
    PORT="$input"
    read -r -p "日志级别 [${LOG_LEVEL}]: " input
    LOG_LEVEL="${input:-$LOG_LEVEL}"
    validate_log_level "$LOG_LEVEL" || die "日志级别无效。"
    save_state
    write_config
    if ! restart_and_verify; then
        install -m 0640 -o root -g "$SERVICE_GROUP" "$backup_state" "$STATE_FILE"
        load_state
        write_config
        restart_and_verify || true
        die "新配置启动失败，已回滚。"
    fi
    sync_firewall
    info "基础配置已更新。"
    show_config
}

manage_padding() {
    require_installed
    local choice editor backup
    while true; do
        title "Padding Scheme 管理"
        printf '1) 查看\n2) 恢复官方默认\n3) 编辑 JSON 数组\n0) 返回\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) jq . "$PADDING_FILE"; pause_menu ;;
            2)
                backup="$(new_temp_dir)/padding.json"
                cp -a "$PADDING_FILE" "$backup"
                write_default_padding
                if ! write_config || ! restart_and_verify; then
                    install -m 0640 -o root -g "$SERVICE_GROUP" "$backup" "$PADDING_FILE"
                    write_config
                    restart_and_verify || true
                    die "Padding Scheme 应用失败，已回滚。"
                fi
                info "已恢复官方默认 Padding Scheme。"
                pause_menu
                ;;
            3)
                backup="$(new_temp_dir)/padding.json"
                cp -a "$PADDING_FILE" "$backup"
                if command -v nano >/dev/null 2>&1; then
                    editor="nano"
                elif command -v vi >/dev/null 2>&1; then
                    editor="vi"
                else
                    apt_install nano
                    editor="nano"
                fi
                "$editor" "$PADDING_FILE"
                chown root:"$SERVICE_GROUP" "$PADDING_FILE"
                chmod 0640 "$PADDING_FILE"
                if ! jq -e 'type == "array" and length > 0 and all(.[]; type == "string")' "$PADDING_FILE" >/dev/null || ! write_config || ! restart_and_verify; then
                    install -m 0640 -o root -g "$SERVICE_GROUP" "$backup" "$PADDING_FILE"
                    write_config
                    restart_and_verify || true
                    die "Padding Scheme 无效，已回滚。"
                fi
                info "Padding Scheme 已更新。"
                pause_menu
                ;;
            0) return ;;
            *) warn "无效选项。" ;;
        esac
    done
}

urlencode() {
    jq -rn --arg value "$1" '$value | @uri'
}

format_host() {
    if [[ "$1" == *:* && "$1" != \[*\] ]]; then
        printf '[%s]\n' "$1"
    else
        printf '%s\n' "$1"
    fi
}

show_config() {
    require_installed
    local host insecure_number user name password label uri
    host="$(format_host "$SERVER_ADDR")"
    [[ "$INSECURE" == "true" ]] && insecure_number=1 || insecure_number=0
    title "AnyTLS 客户端配置"
    printf '服务器: %s\n端口: %s\nSNI: %s\n证书模式: %s\n跳过证书验证: %s\n' \
        "$SERVER_ADDR" "$PORT" "$SNI" "$CERT_MODE" "$INSECURE"
    while IFS= read -r user; do
        name="$(jq -r '.name' <<<"$user")"
        password="$(jq -r '.password' <<<"$user")"
        label="AnyTLS-${name}"
        uri="anytls://$(urlencode "$password")@${host}:${PORT}?security=tls&sni=$(urlencode "$SNI")&insecure=${insecure_number}&type=tcp#$(urlencode "$label")"
        printf '\n[%s]\n密码: %s\n分享链接:\n%s\n' "$name" "$password" "$uri"
        printf '\nsing-box 出站:\n'
        jq -n \
            --arg tag "$label" --arg server "$SERVER_ADDR" --argjson port "$PORT" \
            --arg password "$password" --arg sni "$SNI" --argjson insecure "$INSECURE" \
            '{type:"anytls", tag:$tag, server:$server, server_port:$port, password:$password, tls:{enabled:true, server_name:$sni, insecure:$insecure}}'
        printf '\nMihomo/Clash.Meta:\n'
        jq -nr \
            --arg name "$label" --arg server "$SERVER_ADDR" --arg port "$PORT" \
            --arg password "$password" --arg sni "$SNI" --arg insecure "$INSECURE" \
            '"- name: \"\($name)\"\n  type: anytls\n  server: \($server)\n  port: \($port)\n  password: \"\($password)\"\n  sni: \($sni)\n  skip-cert-verify: \($insecure)\n  udp: true"'
    done < <(jq -c '.[]' "$USERS_FILE")
}

show_status() {
    require_installed
    title "服务状态"
    printf 'sing-box: %s\n' "$(installed_version)"
    printf 'systemd: %s / %s\n\n' "$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)" "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
    systemctl status "$SERVICE_NAME" --no-pager -l || true
}

show_logs() {
    require_installed
    journalctl -u "$SERVICE_NAME" -f -n 100 --no-pager
}

start_service() {
    require_installed
    systemctl start "$SERVICE_NAME"
    service_healthy || die "服务启动失败。"
    info "服务已启动。"
}

stop_service() {
    require_installed
    systemctl stop "$SERVICE_NAME"
    info "服务已停止。"
}

restart_service() {
    require_installed
    restart_and_verify || die "服务重启失败。"
    info "服务已重启。"
}

enable_network_optimization() {
    cat >"$SYSCTL_FILE" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
EOF
    sysctl --system >/dev/null
    info "已尝试启用 BBR、FQ 和 TCP Fast Open。"
    sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_fastopen
}

uninstall_anytls() {
    require_installed
    confirm "确定卸载 AnyTLS Ubuntu 版吗？" || return 0
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    remove_ufw_port "${MANAGED_UFW_PORT:-}"
    [[ "${MANAGED_UFW_80:-false}" == "true" ]] && remove_ufw_port 80
    rm -f -- "$SERVICE_FILE" "$BIN_PATH" "$CERTBOT_HOOK" "$SYSCTL_FILE"
    rm -rf -- "$LIB_DIR" "$CONFIG_DIR"
    systemctl daemon-reload
    if id "$SERVICE_USER" >/dev/null 2>&1; then
        userdel "$SERVICE_USER" >/dev/null 2>&1 || true
    fi
    warn "Certbot 证书和 Certbot 软件已保留，避免误删其他站点证书。"
    info "AnyTLS Ubuntu 版已卸载。"
}

service_menu() {
    require_installed
    title "服务管理"
    printf '1) 启动\n2) 停止\n3) 重启\n4) 状态\n0) 返回\n'
    read -r -p "请选择: " choice
    case "$choice" in
        1) start_service ;;
        2) stop_service ;;
        3) restart_service ;;
        4) show_status ;;
        0) return ;;
        *) warn "无效选项。" ;;
    esac
}

show_help() {
    cat <<EOF
AnyTLS Ubuntu 证书版一键脚本 v${SCRIPT_VERSION}

用法: bash $0 [command]

命令:
  install-ip    纯 IP 零问题安装（无域名，推荐）
  install-domain [域名] [邮箱]
                自动申请域名证书并安装
  install       选择纯 IP、域名或高级安装
  update        更新到最新稳定版 sing-box
  cert          证书管理
  renew         检查并续期 Let's Encrypt 证书
  users         用户管理
  config        修改端口、连接地址和日志级别
  padding       管理 Padding Scheme
  show          显示客户端配置和分享链接
  start|stop|restart|status|logs
  bbr           启用 BBR/FQ/TCP Fast Open
  uninstall     卸载
  help          显示帮助

无参数运行时显示交互菜单。纯 IP 用户直接使用 install-ip 即可。
EOF
}

show_menu() {
    while true; do
        title "AnyTLS Ubuntu 证书版 v${SCRIPT_VERSION}"
        if is_installed; then
            load_state
            printf '状态: %s | sing-box %s | %s:%s | 证书: %s\n\n' \
                "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)" "$(installed_version)" "$SERVER_ADDR" "$PORT" "$CERT_MODE"
        else
            printf '状态: 未安装\n\n'
        fi
        printf '1) 安装/重新安装（默认纯 IP，无需域名）\n'
        printf '2) 更新 sing-box 核心\n'
        printf '3) 证书管理\n'
        printf '4) 用户管理\n'
        printf '5) 修改基础配置\n'
        printf '6) Padding Scheme\n'
        printf '7) 查看客户端配置\n'
        printf '8) 服务管理\n'
        printf '9) 查看状态\n'
        printf '10) 实时日志\n'
        printf '11) 网络优化 BBR\n'
        printf '12) 卸载\n'
        printf '0) 退出\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) install_anytls; pause_menu ;;
            2) update_anytls; pause_menu ;;
            3) certificate_menu ;;
            4) users_menu ;;
            5) change_config; pause_menu ;;
            6) manage_padding ;;
            7) show_config; pause_menu ;;
            8) service_menu; pause_menu ;;
            9) show_status; pause_menu ;;
            10) show_logs ;;
            11) enable_network_optimization; pause_menu ;;
            12) uninstall_anytls; pause_menu ;;
            0) exit 0 ;;
            *) warn "无效选项。" ;;
        esac
    done
}

main() {
    local command="${1:-menu}"
    if [[ "$command" =~ ^(-h|--help|help)$ ]]; then
        show_help
        exit 0
    fi
    check_root
    check_system
    case "$command" in
        menu) show_menu ;;
        install) install_anytls select ;;
        install-ip) install_anytls ip ;;
        install-domain) install_anytls domain "${2:-}" "${3:-}" ;;
        update) update_anytls ;;
        cert) certificate_menu ;;
        renew) renew_certificate ;;
        users) users_menu ;;
        config) change_config ;;
        padding) manage_padding ;;
        show) show_config ;;
        start) start_service ;;
        stop) stop_service ;;
        restart) restart_service ;;
        status) show_status ;;
        logs) show_logs ;;
        bbr) enable_network_optimization ;;
        uninstall) uninstall_anytls ;;
        *) show_help; die "未知命令：${command}" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
