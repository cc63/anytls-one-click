#!/usr/bin/env bash

# AnyTLS Server 一键管理脚本
# 官方核心: https://github.com/anytls/anytls-go

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

set -o pipefail

SCRIPT_VERSION="1.0.0"
GITHUB_REPO="anytls/anytls-go"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
GITHUB_RELEASES="https://github.com/${GITHUB_REPO}/releases"

ANYTLS_DIR="/etc/anytls"
ANYTLS_BIN="/usr/local/bin/anytls-server"
ANYTLS_CONFIG="${ANYTLS_DIR}/config.env"
ANYTLS_PADDING="${ANYTLS_DIR}/padding.conf"
ANYTLS_VERSION_FILE="${ANYTLS_DIR}/version"
ANYTLS_FIREWALL_STATE="${ANYTLS_DIR}/firewall.state"
ANYTLS_IDENTITY_STATE="${ANYTLS_DIR}/identity.state"
ANYTLS_SERVICE="/etc/systemd/system/anytls-server.service"
ANYTLS_SYSCTL="/etc/sysctl.d/99-anytls.conf"
ANYTLS_USER="anytls"
ANYTLS_GROUP="anytls"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_GREEN='\033[32m'
    C_RED='\033[31m'
    C_YELLOW='\033[33m'
    C_CYAN='\033[36m'
    C_RESET='\033[0m'
else
    C_GREEN=''
    C_RED=''
    C_YELLOW=''
    C_CYAN=''
    C_RESET=''
fi

info() { printf '%b\n' "${C_GREEN}[信息]${C_RESET} $*"; }
warn() { printf '%b\n' "${C_YELLOW}[提示]${C_RESET} $*"; }
error() { printf '%b\n' "${C_RED}[错误]${C_RESET} $*" >&2; }
die() { error "$*"; exit 1; }

pause_menu() {
    [[ -t 0 ]] || return 0
    printf '\n按回车返回主菜单...'
    read -r _
}

confirm() {
    local prompt="$1"
    local default_answer="${2:-n}"
    local answer

    if [[ ! -t 0 ]]; then
        [[ "$default_answer" == "y" ]]
        return
    fi

    if [[ "$default_answer" == "y" ]]; then
        read -r -p "${prompt} [Y/n]: " answer
        answer="${answer:-y}"
    else
        read -r -p "${prompt} [y/N]: " answer
        answer="${answer:-n}"
    fi
    [[ "$answer" =~ ^[Yy]$ ]]
}

check_root() {
    [[ "${EUID}" -eq 0 ]] || die "请使用 root 用户运行，例如：sudo bash $0"
}

check_system() {
    [[ "$(uname -s)" == "Linux" ]] || die "本脚本只支持 Linux。"
    command -v systemctl >/dev/null 2>&1 || die "未检测到 systemd，本脚本暂不支持该系统。"
    [[ -d /run/systemd/system ]] || die "systemd 当前未作为 PID 1 运行。"
}

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PACKAGE_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PACKAGE_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PACKAGE_MANAGER="yum"
    else
        die "仅支持 Debian/Ubuntu、CentOS/RHEL、Rocky Linux、AlmaLinux、Fedora。"
    fi
}

install_dependencies() {
    local missing=0
    local command_name

    for command_name in curl unzip openssl ss; do
        command -v "$command_name" >/dev/null 2>&1 || missing=1
    done
    [[ "$missing" -eq 0 ]] && return 0

    detect_package_manager
    info "正在安装 curl、unzip、openssl、ca-certificates 和网络工具..."
    case "$PACKAGE_MANAGER" in
        apt)
            apt-get update || die "apt 软件源更新失败。"
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                curl unzip openssl ca-certificates iproute2 || die "依赖安装失败。"
            ;;
        dnf)
            dnf install -y curl unzip openssl ca-certificates iproute || die "依赖安装失败。"
            ;;
        yum)
            yum install -y curl unzip openssl ca-certificates iproute || die "依赖安装失败。"
            ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            ANYTLS_ARCH="amd64"
            ;;
        aarch64|arm64)
            ANYTLS_ARCH="arm64"
            ;;
        *)
            die "官方 anytls-go 暂未发布 $(uname -m) 架构的 Linux 二进制，仅支持 amd64/arm64。"
            ;;
    esac
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

validate_bind() {
    local bind="$1"
    [[ -n "$bind" && "$bind" != *[[:space:]]* && "$bind" =~ ^[A-Za-z0-9:._%\-]+$ ]]
}

validate_password() {
    local password="$1"
    (( ${#password} >= 16 && ${#password} <= 128 )) || return 1
    [[ "$password" =~ ^[A-Za-z0-9._~-]+$ ]]
}

validate_log_level() {
    [[ "$1" =~ ^(panic|fatal|error|warn|warning|info|debug|trace)$ ]]
}

format_listen() {
    local bind="$1"
    local port="$2"

    bind="${bind#[}"
    bind="${bind%]}"
    if [[ "$bind" == *:* ]]; then
        printf '[%s]:%s\n' "$bind" "$port"
    else
        printf '%s:%s\n' "$bind" "$port"
    fi
}

generate_password() {
    openssl rand -hex 20
}

port_is_listening() {
    local port="$1"
    ss -H -ltn 2>/dev/null | awk -v wanted=":${port}" '
        {
            address=$4
            sub(/%.*/, "", address)
            if (length(address) >= length(wanted) && substr(address, length(address)-length(wanted)+1) == wanted) {
                found=1
            }
        }
        END { exit !found }
    '
}

create_service_user() {
    CREATED_ANYTLS_GROUP=0
    CREATED_ANYTLS_USER=0
    if [[ -s "$ANYTLS_IDENTITY_STATE" ]]; then
        grep -q '^group_created=1$' "$ANYTLS_IDENTITY_STATE" && CREATED_ANYTLS_GROUP=1
        grep -q '^user_created=1$' "$ANYTLS_IDENTITY_STATE" && CREATED_ANYTLS_USER=1
    fi
    if ! getent group "$ANYTLS_GROUP" >/dev/null 2>&1; then
        groupadd --system "$ANYTLS_GROUP" || die "创建 ${ANYTLS_GROUP} 用户组失败。"
        CREATED_ANYTLS_GROUP=1
    fi
    if ! id "$ANYTLS_USER" >/dev/null 2>&1; then
        local nologin_shell
        nologin_shell="$(command -v nologin 2>/dev/null || true)"
        [[ -n "$nologin_shell" ]] || nologin_shell="/usr/sbin/nologin"
        useradd --system --gid "$ANYTLS_GROUP" --no-create-home \
            --home-dir /nonexistent --shell "$nologin_shell" "$ANYTLS_USER" || \
            die "创建 ${ANYTLS_USER} 系统用户失败。"
        CREATED_ANYTLS_USER=1
    fi
}

write_identity_state() {
    {
        printf 'group_created=%s\n' "${CREATED_ANYTLS_GROUP:-0}"
        printf 'user_created=%s\n' "${CREATED_ANYTLS_USER:-0}"
    } > "$ANYTLS_IDENTITY_STATE"
    chmod 0600 "$ANYTLS_IDENTITY_STATE"
}

default_padding_scheme() {
    printf '%s\n' \
        'stop=8' \
        '0=30-30' \
        '1=100-400' \
        '2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000' \
        '3=9-9,500-1000' \
        '4=500-1000' \
        '5=500-1000' \
        '6=500-1000' \
        '7=500-1000'
}

write_default_padding() {
    local temp_file
    temp_file="$(mktemp)" || die "无法创建临时文件。"
    default_padding_scheme > "$temp_file"
    install -o root -g "$ANYTLS_GROUP" -m 0644 "$temp_file" "$ANYTLS_PADDING"
    rm -f "$temp_file"
}

write_config() {
    local bind="$1"
    local port="$2"
    local password="$3"
    local log_level="$4"
    local listen_value temp_file

    listen_value="$(format_listen "$bind" "$port")"
    temp_file="$(mktemp)" || die "无法创建临时文件。"
    {
        printf '# AnyTLS Server 配置，由 anytls.sh 管理\n'
        printf 'ANYTLS_BIND="%s"\n' "$bind"
        printf 'ANYTLS_PORT="%s"\n' "$port"
        printf 'ANYTLS_LISTEN="%s"\n' "$listen_value"
        printf 'ANYTLS_PASSWORD="%s"\n' "$password"
        printf 'ANYTLS_PADDING_FILE="%s"\n' "$ANYTLS_PADDING"
        printf 'LOG_LEVEL="%s"\n' "$log_level"
    } > "$temp_file"
    install -o root -g "$ANYTLS_GROUP" -m 0640 "$temp_file" "$ANYTLS_CONFIG"
    rm -f "$temp_file"
}

load_config() {
    [[ -f "$ANYTLS_CONFIG" ]] || die "配置文件不存在：${ANYTLS_CONFIG}"
    # shellcheck disable=SC1090
    source "$ANYTLS_CONFIG"
    : "${ANYTLS_BIND:?配置缺少 ANYTLS_BIND}"
    : "${ANYTLS_PORT:?配置缺少 ANYTLS_PORT}"
    : "${ANYTLS_LISTEN:?配置缺少 ANYTLS_LISTEN}"
    : "${ANYTLS_PASSWORD:?配置缺少 ANYTLS_PASSWORD}"
    : "${ANYTLS_PADDING_FILE:?配置缺少 ANYTLS_PADDING_FILE}"
    : "${LOG_LEVEL:?配置缺少 LOG_LEVEL}"
}

write_service() {
    local temp_file
    temp_file="$(mktemp)" || die "无法创建临时文件。"
    {
        printf '%s\n' \
            '[Unit]' \
            'Description=AnyTLS Server' \
            'Documentation=https://github.com/anytls/anytls-go' \
            'After=network-online.target' \
            'Wants=network-online.target' \
            '' \
            '[Service]' \
            'Type=simple' \
            "User=${ANYTLS_USER}" \
            "Group=${ANYTLS_GROUP}" \
            "EnvironmentFile=${ANYTLS_CONFIG}" \
            'ExecStart=/usr/local/bin/anytls-server -l ${ANYTLS_LISTEN} -p ${ANYTLS_PASSWORD} -padding-scheme ${ANYTLS_PADDING_FILE}' \
            'Restart=on-failure' \
            'RestartSec=3s' \
            'LimitNOFILE=1048576' \
            'AmbientCapabilities=CAP_NET_BIND_SERVICE' \
            'CapabilityBoundingSet=CAP_NET_BIND_SERVICE' \
            'NoNewPrivileges=true' \
            'PrivateTmp=true' \
            'PrivateDevices=true' \
            'ProtectSystem=strict' \
            'ProtectHome=true' \
            'ProtectKernelTunables=true' \
            'ProtectKernelModules=true' \
            'ProtectControlGroups=true' \
            'RestrictSUIDSGID=true' \
            'LockPersonality=true' \
            'RestrictRealtime=true' \
            'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6' \
            'UMask=0077' \
            '' \
            '[Install]' \
            'WantedBy=multi-user.target'
    } > "$temp_file"
    install -o root -g root -m 0644 "$temp_file" "$ANYTLS_SERVICE"
    rm -f "$temp_file"
    systemctl daemon-reload
}

get_latest_release() {
    local api_response latest_url tag asset_name compact_response asset_tail digest_tail

    detect_arch

    api_response="$(curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 \
        --max-time 30 --retry 3 --retry-delay 2 \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: anytls-one-click-script' "$GITHUB_API" 2>/dev/null || true)"
    tag="$(printf '%s\n' "$api_response" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"

    if [[ -z "$tag" ]]; then
        latest_url="$(curl --proto '=https' --tlsv1.2 -fsSLI --connect-timeout 10 \
            --max-time 30 --retry 2 -o /dev/null -w '%{url_effective}' \
            "${GITHUB_RELEASES}/latest" 2>/dev/null || true)"
        tag="${latest_url##*/}"
    fi

    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || \
        die "无法从 GitHub 获取 AnyTLS 最新版本，请稍后重试。"

    LATEST_TAG="$tag"
    LATEST_VERSION="${tag#v}"
    LATEST_SHA256=""
    if [[ -n "$api_response" ]]; then
        asset_name="anytls_${LATEST_VERSION}_linux_${ANYTLS_ARCH}.zip"
        compact_response="$(printf '%s' "$api_response" | tr -d '[:space:]')"
        if [[ "$compact_response" == *"\"name\":\"${asset_name}\""* ]]; then
            asset_tail="${compact_response#*\"name\":\"${asset_name}\"}"
            if [[ "$asset_tail" == *'"digest":"sha256:'* ]]; then
                digest_tail="${asset_tail#*\"digest\":\"sha256:}"
                LATEST_SHA256="${digest_tail%%\"*}"
            fi
        fi
        [[ "$LATEST_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || LATEST_SHA256=""
    fi
}

verify_archive_checksum() {
    local archive="$1"
    local expected="$2"
    local actual

    if [[ -z "$expected" ]]; then
        warn "官方 API 未返回该资产的 SHA-256 摘要，将仅进行 HTTPS、压缩包和二进制自检。"
        return 0
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$archive" | awk '{print $1}')"
    else
        actual="$(openssl dgst -sha256 "$archive" | awk '{print $NF}')"
    fi
    actual="$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')"
    expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
    [[ "$actual" == "$expected" ]] || \
        die "下载文件的 SHA-256 与 GitHub 官方摘要不一致，已停止安装。"
    info "GitHub 官方 SHA-256 摘要校验通过。"
}

download_release() {
    local version="$1"
    local destination="$2"
    local url

    detect_arch
    url="https://github.com/${GITHUB_REPO}/releases/download/v${version}/anytls_${version}_linux_${ANYTLS_ARCH}.zip"
    info "正在下载 AnyTLS v${version} (${ANYTLS_ARCH})..."
    curl --proto '=https' --tlsv1.2 -fL --connect-timeout 15 --max-time 300 \
        --retry 3 --retry-delay 2 --progress-bar "$url" -o "$destination" || \
        die "下载失败：${url}"
    if [[ "$version" == "${LATEST_VERSION:-}" ]]; then
        verify_archive_checksum "$destination" "${LATEST_SHA256:-}"
    fi
}

verify_server_binary() {
    local binary="$1"
    local help_output

    [[ -s "$binary" ]] || return 1
    chmod 0755 "$binary" || return 1
    help_output="$("$binary" -h 2>&1 || true)"
    printf '%s\n' "$help_output" | grep -q -- '-padding-scheme'
}

prepare_release_binary() {
    local version="$1"
    local work_dir archive extracted

    work_dir="$(mktemp -d)" || die "无法创建临时目录。"
    archive="${work_dir}/anytls.zip"
    download_release "$version" "$archive"
    unzip -q "$archive" -d "$work_dir" || {
        rm -rf "$work_dir"
        die "AnyTLS 压缩包解压失败。"
    }
    extracted="${work_dir}/anytls-server"
    if ! verify_server_binary "$extracted"; then
        rm -rf "$work_dir"
        die "下载到的 anytls-server 校验失败或与当前架构不兼容。"
    fi
    PREPARED_BINARY="$extracted"
    PREPARED_WORK_DIR="$work_dir"
}

install_prepared_binary() {
    local binary="$1"
    local target_temp="${ANYTLS_BIN}.new"

    install -o root -g root -m 0755 "$binary" "$target_temp" || die "安装 AnyTLS 二进制失败。"
    mv -f "$target_temp" "$ANYTLS_BIN" || die "替换 AnyTLS 二进制失败。"
}

is_installed() {
    [[ -x "$ANYTLS_BIN" && -f "$ANYTLS_CONFIG" && -f "$ANYTLS_SERVICE" ]]
}

require_installed() {
    is_installed || die "AnyTLS Server 尚未安装，请先执行安装。"
}

installed_version() {
    if [[ -s "$ANYTLS_VERSION_FILE" ]]; then
        tr -d '[:space:]' < "$ANYTLS_VERSION_FILE"
    else
        printf '未知'
    fi
}

prompt_install_config() {
    local input

    read -r -p "监听地址（默认 0.0.0.0；双栈可填 ::）: " input
    INSTALL_BIND="${input:-0.0.0.0}"
    validate_bind "$INSTALL_BIND" || die "监听地址格式不正确。"

    while true; do
        read -r -p "监听端口（默认 8443）: " input
        INSTALL_PORT="${input:-8443}"
        validate_port "$INSTALL_PORT" && break
        warn "端口必须是 1-65535 的整数。"
    done
    if port_is_listening "$INSTALL_PORT"; then
        confirm "端口 ${INSTALL_PORT} 当前已被监听，仍要继续吗？" n || die "已取消安装。"
    fi

    INSTALL_PASSWORD="$(generate_password)"
    printf '已生成随机密码：%b%s%b\n' "$C_CYAN" "$INSTALL_PASSWORD" "$C_RESET"
    if confirm "是否手动设置密码？（仅允许 16-128 位 URL 安全字符）" n; then
        while true; do
            read -r -p "请输入密码: " input
            if validate_password "$input"; then
                INSTALL_PASSWORD="$input"
                break
            fi
            warn "密码需为 16-128 位，仅可使用字母、数字及 . _ ~ -"
        done
    fi

    while true; do
        read -r -p "日志级别 panic/fatal/error/warn/info/debug/trace（默认 info）: " input
        INSTALL_LOG_LEVEL="${input:-info}"
        validate_log_level "$INSTALL_LOG_LEVEL" && break
        warn "日志级别无效。"
    done
}

open_firewall_port() {
    local port="$1"
    local state=""

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        if ufw status 2>/dev/null | grep -Eq "^${port}/tcp[[:space:]]+ALLOW"; then
            info "UFW 已放行 TCP ${port}，未重复添加规则。"
        elif ufw allow "${port}/tcp" comment 'AnyTLS' >/dev/null; then
            state="ufw:${port}"
            info "已通过 UFW 放行 TCP ${port}。"
        else
            warn "UFW 端口放行失败，请手动放行 TCP ${port}。"
        fi
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        if firewall-cmd --permanent --query-port="${port}/tcp" >/dev/null 2>&1; then
            info "firewalld 已放行 TCP ${port}，未重复添加规则。"
        elif firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null && \
            firewall-cmd --reload >/dev/null; then
            state="firewalld:${port}"
            info "已通过 firewalld 放行 TCP ${port}。"
        else
            warn "firewalld 端口放行失败，请手动放行 TCP ${port}。"
        fi
    else
        warn "未检测到活动的 UFW/firewalld；如云厂商有安全组，请手动放行 TCP ${port}。"
    fi

    if [[ -n "$state" ]]; then
        printf '%s\n' "$state" > "$ANYTLS_FIREWALL_STATE"
        chmod 0600 "$ANYTLS_FIREWALL_STATE"
    fi
}

remove_managed_firewall_rule() {
    [[ -s "$ANYTLS_FIREWALL_STATE" ]] || return 0
    local state backend port
    state="$(tr -d '[:space:]' < "$ANYTLS_FIREWALL_STATE")"
    backend="${state%%:*}"
    port="${state##*:}"

    case "$backend" in
        ufw)
            if command -v ufw >/dev/null 2>&1; then
                ufw --force delete allow "${port}/tcp" >/dev/null 2>&1 || true
                info "已移除脚本添加的 UFW TCP ${port} 规则。"
            fi
            ;;
        firewalld)
            if command -v firewall-cmd >/dev/null 2>&1; then
                firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
                firewall-cmd --reload >/dev/null 2>&1 || true
                info "已移除脚本添加的 firewalld TCP ${port} 规则。"
            fi
            ;;
    esac
    rm -f "$ANYTLS_FIREWALL_STATE"
}

install_anytls() {
    check_root
    check_system
    if is_installed; then
        warn "AnyTLS 已安装，若要升级请使用“更新 AnyTLS 核心”。"
        return 0
    fi
    if [[ -e "$ANYTLS_BIN" || -e "$ANYTLS_SERVICE" || -e "$ANYTLS_CONFIG" || -e "$ANYTLS_DIR" ]]; then
        confirm "检测到不完整或其他来源的 AnyTLS 文件，是否由本脚本接管并覆盖？" n || \
            die "已取消安装。"
    fi

    install_dependencies
    detect_arch
    prompt_install_config
    get_latest_release
    info "检测到官方最新版本：v${LATEST_VERSION}"
    prepare_release_binary "$LATEST_VERSION"

    create_service_user
    install -d -o root -g "$ANYTLS_GROUP" -m 0750 "$ANYTLS_DIR"
    write_identity_state
    write_config "$INSTALL_BIND" "$INSTALL_PORT" "$INSTALL_PASSWORD" "$INSTALL_LOG_LEVEL"
    write_default_padding
    install_prepared_binary "$PREPARED_BINARY"
    rm -rf "$PREPARED_WORK_DIR"
    printf '%s\n' "$LATEST_VERSION" > "$ANYTLS_VERSION_FILE"
    chmod 0644 "$ANYTLS_VERSION_FILE"
    write_service

    if ! systemctl enable --now anytls-server.service; then
        error "服务启动失败，最近日志如下："
        journalctl -u anytls-server.service -n 30 --no-pager || true
        die "AnyTLS 安装文件已保留，请根据日志排查。"
    fi

    if confirm "是否自动放行防火墙 TCP ${INSTALL_PORT}？" y; then
        open_firewall_port "$INSTALL_PORT"
    fi

    info "AnyTLS Server v${LATEST_VERSION} 安装并启动成功。"
    warn "官方参考服务端使用运行时自签证书，客户端必须启用 insecure/跳过证书验证。"
    show_config
}

update_anytls() {
    local current backup_dir old_version

    check_root
    check_system
    require_installed
    install_dependencies
    get_latest_release
    current="$(installed_version)"
    info "当前版本：v${current}；官方最新版本：v${LATEST_VERSION}"

    if [[ "$current" == "$LATEST_VERSION" ]]; then
        confirm "当前已是最新版，是否强制重新安装？" n || return 0
    fi

    prepare_release_binary "$LATEST_VERSION"
    backup_dir="$(mktemp -d)" || die "无法创建更新备份目录。"
    cp -p "$ANYTLS_BIN" "${backup_dir}/anytls-server" || die "备份当前二进制失败。"
    old_version="$current"

    install_prepared_binary "$PREPARED_BINARY"
    printf '%s\n' "$LATEST_VERSION" > "$ANYTLS_VERSION_FILE"
    chmod 0644 "$ANYTLS_VERSION_FILE"

    if systemctl restart anytls-server.service && systemctl is-active --quiet anytls-server.service; then
        rm -rf "$PREPARED_WORK_DIR" "$backup_dir"
        info "AnyTLS 已更新到 v${LATEST_VERSION}，原配置保持不变。"
    else
        error "新版本启动失败，正在自动回滚..."
        install -o root -g root -m 0755 "${backup_dir}/anytls-server" "$ANYTLS_BIN"
        printf '%s\n' "$old_version" > "$ANYTLS_VERSION_FILE"
        systemctl restart anytls-server.service || true
        rm -rf "$PREPARED_WORK_DIR" "$backup_dir"
        journalctl -u anytls-server.service -n 30 --no-pager || true
        die "更新失败，已回滚到 v${old_version}。"
    fi
}

uninstall_anytls() {
    local remove_user=0 remove_group=0

    check_root
    check_system
    require_installed
    confirm "确定要卸载 AnyTLS Server 及其配置吗？" n || {
        info "已取消卸载。"
        return 0
    }

    if [[ -s "$ANYTLS_IDENTITY_STATE" ]]; then
        grep -q '^user_created=1$' "$ANYTLS_IDENTITY_STATE" && remove_user=1
        grep -q '^group_created=1$' "$ANYTLS_IDENTITY_STATE" && remove_group=1
    fi

    systemctl disable --now anytls-server.service >/dev/null 2>&1 || true
    remove_managed_firewall_rule
    rm -f "$ANYTLS_SERVICE" "$ANYTLS_BIN"
    rm -rf "$ANYTLS_DIR"
    systemctl daemon-reload
    systemctl reset-failed anytls-server.service >/dev/null 2>&1 || true

    if [[ "$remove_user" -eq 1 ]] && id "$ANYTLS_USER" >/dev/null 2>&1; then
        userdel "$ANYTLS_USER" >/dev/null 2>&1 || true
    fi
    if [[ "$remove_group" -eq 1 ]] && getent group "$ANYTLS_GROUP" >/dev/null 2>&1; then
        groupdel "$ANYTLS_GROUP" >/dev/null 2>&1 || true
    fi

    if [[ -f "$ANYTLS_SYSCTL" ]]; then
        warn "网络优化配置 ${ANYTLS_SYSCTL} 可能仍被其他服务使用，因此未自动删除。"
    fi
    info "AnyTLS Server 已卸载。"
}

start_anytls() {
    check_root
    require_installed
    systemctl start anytls-server.service || die "启动失败，请查看日志。"
    info "AnyTLS Server 已启动。"
}

stop_anytls() {
    check_root
    require_installed
    systemctl stop anytls-server.service || die "停止失败。"
    info "AnyTLS Server 已停止。"
}

restart_anytls() {
    check_root
    require_installed
    systemctl restart anytls-server.service || die "重启失败，请查看日志。"
    info "AnyTLS Server 已重启。"
}

change_config() {
    local old_bind old_port old_password old_log input new_bind new_port new_password new_log backup

    check_root
    check_system
    require_installed
    load_config
    old_bind="$ANYTLS_BIND"
    old_port="$ANYTLS_PORT"
    old_password="$ANYTLS_PASSWORD"
    old_log="$LOG_LEVEL"

    read -r -p "监听地址（当前 ${old_bind}，回车保持）: " input
    new_bind="${input:-$old_bind}"
    validate_bind "$new_bind" || die "监听地址格式不正确。"

    while true; do
        read -r -p "监听端口（当前 ${old_port}，回车保持）: " input
        new_port="${input:-$old_port}"
        validate_port "$new_port" && break
        warn "端口必须是 1-65535 的整数。"
    done
    if [[ "$new_port" != "$old_port" ]] && port_is_listening "$new_port"; then
        confirm "端口 ${new_port} 当前已被监听，仍要使用吗？" n || return 0
    fi

    read -r -p "密码（回车保持；输入 r 自动生成）: " input
    if [[ -z "$input" ]]; then
        new_password="$old_password"
    elif [[ "$input" == "r" || "$input" == "R" ]]; then
        new_password="$(generate_password)"
        info "已生成新密码：${new_password}"
    else
        validate_password "$input" || die "密码需为 16-128 位，仅可使用字母、数字及 . _ ~ -"
        new_password="$input"
    fi

    while true; do
        read -r -p "日志级别（当前 ${old_log}，回车保持）: " input
        new_log="${input:-$old_log}"
        validate_log_level "$new_log" && break
        warn "日志级别无效。"
    done

    backup="$(mktemp)" || die "无法创建配置备份。"
    cp -p "$ANYTLS_CONFIG" "$backup" || die "备份配置失败。"
    write_config "$new_bind" "$new_port" "$new_password" "$new_log"

    if systemctl restart anytls-server.service && systemctl is-active --quiet anytls-server.service; then
        rm -f "$backup"
        if [[ "$new_port" != "$old_port" ]]; then
            remove_managed_firewall_rule
            if confirm "是否自动放行新端口 TCP ${new_port}？" y; then
                open_firewall_port "$new_port"
            fi
        fi
        info "配置已更新并生效。"
        show_config
    else
        error "新配置启动失败，正在恢复原配置..."
        install -o root -g "$ANYTLS_GROUP" -m 0640 "$backup" "$ANYTLS_CONFIG"
        rm -f "$backup"
        systemctl restart anytls-server.service || true
        journalctl -u anytls-server.service -n 30 --no-pager || true
        die "配置修改失败，已恢复原配置。"
    fi
}

validate_padding_scheme() {
    local file="$1"
    local output

    grep -Eq '^stop=[0-9]+$' "$file" || return 1
    if command -v timeout >/dev/null 2>&1 && [[ -x "$ANYTLS_BIN" ]]; then
        output="$(LOG_LEVEL=info timeout 2 "$ANYTLS_BIN" -l 127.0.0.1:0 \
            -p padding-validator -padding-scheme "$file" 2>&1 || true)"
        printf '%s\n' "$output" | grep -q 'loaded padding scheme file:' || return 1
    fi
    return 0
}

choose_editor() {
    if [[ -n "${EDITOR:-}" ]] && command -v "${EDITOR%% *}" >/dev/null 2>&1; then
        printf '%s\n' "$EDITOR"
    elif command -v nano >/dev/null 2>&1; then
        printf 'nano\n'
    elif command -v vi >/dev/null 2>&1; then
        printf 'vi\n'
    else
        return 1
    fi
}

manage_padding() {
    local choice editor backup

    check_root
    check_system
    require_installed
    printf '\n%s\n' \
        '1. 查看当前 Padding Scheme' \
        '2. 重置为官方默认方案' \
        '3. 使用文本编辑器修改' \
        '0. 返回'
    read -r -p "请选择: " choice
    case "$choice" in
        1)
            printf '\n文件：%s\n------------------------------\n' "$ANYTLS_PADDING"
            sed -n '1,120p' "$ANYTLS_PADDING"
            printf '%s\n' '------------------------------'
            ;;
        2)
            write_default_padding
            systemctl restart anytls-server.service || die "重启失败，请查看日志。"
            info "已恢复官方默认 Padding Scheme。"
            ;;
        3)
            editor="$(choose_editor)" || die "未找到文本编辑器，请安装 nano 或 vi。"
            backup="$(mktemp)" || die "无法创建备份。"
            cp -p "$ANYTLS_PADDING" "$backup" || die "备份 Padding Scheme 失败。"
            # shellcheck disable=SC2086
            $editor "$ANYTLS_PADDING"
            if validate_padding_scheme "$ANYTLS_PADDING"; then
                chown root:"$ANYTLS_GROUP" "$ANYTLS_PADDING"
                chmod 0644 "$ANYTLS_PADDING"
                if systemctl restart anytls-server.service; then
                    rm -f "$backup"
                    info "Padding Scheme 已验证并生效。"
                else
                    install -o root -g "$ANYTLS_GROUP" -m 0644 "$backup" "$ANYTLS_PADDING"
                    rm -f "$backup"
                    systemctl restart anytls-server.service || true
                    die "服务启动失败，已恢复原 Padding Scheme。"
                fi
            else
                install -o root -g "$ANYTLS_GROUP" -m 0644 "$backup" "$ANYTLS_PADDING"
                rm -f "$backup"
                die "Padding Scheme 格式验证失败，已恢复原文件。"
            fi
            ;;
        0|'') return 0 ;;
        *) warn "无效选择。" ;;
    esac
}

get_public_ip() {
    local ip
    ip="$(curl --proto '=https' --tlsv1.2 -4fsS --connect-timeout 3 --max-time 6 \
        https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then
        ip="$(curl --proto '=https' --tlsv1.2 -4fsS --connect-timeout 3 --max-time 6 \
            https://api.ip.sb/ip 2>/dev/null || true)"
    fi
    if [[ -z "$ip" ]]; then
        ip="$(curl --proto '=https' --tlsv1.2 -6fsS --connect-timeout 3 --max-time 6 \
            https://api64.ipify.org 2>/dev/null || true)"
    fi
    printf '%s' "$ip"
}

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

show_config() {
    local public_ip display_host uri_host node_name safe_node version service_state escaped_ip escaped_password

    check_root
    require_installed
    load_config
    public_ip="$(get_public_ip)"
    display_host="${public_ip:-请替换为服务器IP}"
    if [[ "$display_host" == *:* && "$display_host" != 请替换为服务器IP ]]; then
        uri_host="[${display_host}]"
    else
        uri_host="$display_host"
    fi
    node_name="anytls-$(hostname -s 2>/dev/null || printf 'server')"
    safe_node="${node_name// /%20}"
    version="$(installed_version)"
    if systemctl is-active --quiet anytls-server.service; then
        service_state="运行中"
    else
        service_state="已停止"
    fi
    escaped_ip="$(json_escape "$display_host")"
    escaped_password="$(json_escape "$ANYTLS_PASSWORD")"

    printf '\n%bAnyTLS Server 配置信息%b\n' "$C_CYAN" "$C_RESET"
    printf '%s\n' '=================================================='
    printf '版本      : v%s\n' "$version"
    printf '运行状态  : %s\n' "$service_state"
    printf '公网地址  : %s\n' "$display_host"
    printf '监听地址  : %s\n' "$ANYTLS_LISTEN"
    printf '端口      : %s/TCP\n' "$ANYTLS_PORT"
    printf '密码      : %s\n' "$ANYTLS_PASSWORD"
    printf '日志级别  : %s\n' "$LOG_LEVEL"
    printf '配置文件  : %s\n' "$ANYTLS_CONFIG"
    printf '分包配置  : %s\n' "$ANYTLS_PADDING_FILE"
    printf '%s\n' '=================================================='

    printf '\n%b标准 AnyTLS URI（Shadowrocket/Stash/Loon 等）%b\n' "$C_CYAN" "$C_RESET"
    printf 'anytls://%s@%s:%s/?insecure=1#%s\n' \
        "$ANYTLS_PASSWORD" "$uri_host" "$ANYTLS_PORT" "$safe_node"

    printf '\n%bSing-box 出站%b\n' "$C_CYAN" "$C_RESET"
    printf '%s\n' \
        '{' \
        '  "type": "anytls",' \
        '  "tag": "anytls-out",' \
        "  \"server\": \"${escaped_ip}\"," \
        "  \"server_port\": ${ANYTLS_PORT}," \
        "  \"password\": \"${escaped_password}\"," \
        '  "idle_session_check_interval": "30s",' \
        '  "idle_session_timeout": "30s",' \
        '  "min_idle_session": 0,' \
        '  "tls": {' \
        '    "enabled": true,' \
        '    "insecure": true' \
        '  }' \
        '}'

    printf '\n%bMihomo/Clash.Meta 节点%b\n' "$C_CYAN" "$C_RESET"
    printf '%s\n' \
        "- name: \"${node_name}\"" \
        '  type: anytls' \
        "  server: \"${display_host}\"" \
        "  port: ${ANYTLS_PORT}" \
        "  password: \"${ANYTLS_PASSWORD}\"" \
        '  client-fingerprint: chrome' \
        '  udp: true' \
        '  idle-session-check-interval: 30' \
        '  idle-session-timeout: 30' \
        '  min-idle-session: 0' \
        '  skip-cert-verify: true'

    printf '\n'
    warn "官方 anytls-go 参考服务端使用自签证书，上述客户端配置必须保留 insecure/skip-cert-verify。"
}

show_status() {
    check_root
    require_installed
    systemctl status anytls-server.service --no-pager -l || true
}

show_logs() {
    check_root
    require_installed
    if [[ -t 0 ]]; then
        warn "按 Ctrl+C 退出实时日志。"
        journalctl -u anytls-server.service -f -n 100
    else
        journalctl -u anytls-server.service -n 100 --no-pager
    fi
}

enable_network_optimization() {
    local available current temp_file

    check_root
    check_system
    command -v sysctl >/dev/null 2>&1 || die "系统缺少 sysctl。"
    modprobe tcp_bbr >/dev/null 2>&1 || true
    available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    if [[ " $available " != *' bbr '* ]]; then
        die "当前内核未提供 BBR。请先升级内核，当前可用算法：${available:-未知}"
    fi

    temp_file="$(mktemp)" || die "无法创建临时文件。"
    {
        printf '%s\n' \
            '# AnyTLS TCP 网络优化，由 anytls.sh 管理' \
            'net.core.default_qdisc = fq' \
            'net.ipv4.tcp_congestion_control = bbr' \
            'net.ipv4.tcp_fastopen = 3'
    } > "$temp_file"
    install -o root -g root -m 0644 "$temp_file" "$ANYTLS_SYSCTL"
    rm -f "$temp_file"
    sysctl --system >/dev/null || warn "部分 sysctl 配置应用时出现警告，请手动检查。"
    current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    if [[ "$current" == "bbr" ]]; then
        info "BBR 与 TCP Fast Open 已启用并持久化。"
    else
        warn "配置文件已写入，但当前拥塞控制算法为 ${current:-未知}，重启后再检查。"
    fi
}

show_help() {
    printf '%s\n' \
        "AnyTLS Server 管理脚本 v${SCRIPT_VERSION}" \
        '' \
        "用法: sudo bash $0 [命令]" \
        '' \
        '命令:' \
        '  install    安装最新版 AnyTLS Server' \
        '  update     更新/重装最新版核心（保留配置，失败自动回滚）' \
        '  uninstall  卸载服务、核心和配置' \
        '  start      启动服务' \
        '  stop       停止服务' \
        '  restart    重启服务' \
        '  config     修改监听地址、端口、密码和日志级别' \
        '  padding    管理 Padding Scheme' \
        '  show       显示服务端和客户端配置' \
        '  status     查看服务状态' \
        '  logs       查看实时日志' \
        '  optimize   启用 BBR 与 TCP Fast Open' \
        '  menu       显示交互菜单' \
        '  help       显示帮助'
}

show_menu() {
    local choice version state
    while true; do
        if [[ -t 1 ]]; then
            clear 2>/dev/null || true
        fi
        if is_installed; then
            version="v$(installed_version)"
            if systemctl is-active --quiet anytls-server.service; then
                state="${C_GREEN}运行中${C_RESET}"
            else
                state="${C_RED}已停止${C_RESET}"
            fi
        else
            version="未安装"
            state="${C_RED}未安装${C_RESET}"
        fi

        printf '%b\n' "
==================================================
 AnyTLS Server 管理脚本 v${SCRIPT_VERSION}
 当前版本：${version}    状态：${state}
==================================================
  1. 安装 AnyTLS Server
  2. 更新 AnyTLS 核心到最新版
  3. 卸载 AnyTLS Server
--------------------------------------------------
  4. 启动服务
  5. 停止服务
  6. 重启服务
--------------------------------------------------
  7. 修改基础配置
  8. 管理 Padding Scheme
  9. 查看配置与客户端节点
 10. 查看运行状态
 11. 查看实时日志
 12. 启用 BBR 与 TCP Fast Open
--------------------------------------------------
  0. 退出
=================================================="
        read -r -p "请选择 [0-12]: " choice
        case "$choice" in
            1) install_anytls ;;
            2) update_anytls ;;
            3) uninstall_anytls ;;
            4) start_anytls ;;
            5) stop_anytls ;;
            6) restart_anytls ;;
            7) change_config ;;
            8) manage_padding ;;
            9) show_config ;;
            10) show_status ;;
            11) show_logs ;;
            12) enable_network_optimization ;;
            0) exit 0 ;;
            *) warn "请输入 0-12 之间的数字。" ;;
        esac
        pause_menu
    done
}

main() {
    local command="${1:-menu}"
    case "$command" in
        install) install_anytls ;;
        update) update_anytls ;;
        uninstall) uninstall_anytls ;;
        start) start_anytls ;;
        stop) stop_anytls ;;
        restart) restart_anytls ;;
        config) change_config ;;
        padding) manage_padding ;;
        show) show_config ;;
        status) show_status ;;
        logs) show_logs ;;
        optimize) enable_network_optimization ;;
        menu) check_root; check_system; show_menu ;;
        help|-h|--help) show_help ;;
        version|-v|--version) printf '%s\n' "$SCRIPT_VERSION" ;;
        *) error "未知命令：${command}"; show_help; exit 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
