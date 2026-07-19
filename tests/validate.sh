#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "${PROJECT_DIR}/anytls.sh"
bash -n "${PROJECT_DIR}/anytls-ubuntu.sh"
bash "${PROJECT_DIR}/anytls-ubuntu.sh" help >/dev/null

# The source path is resolved dynamically from the repository root.
# shellcheck disable=SC1091
. "${PROJECT_DIR}/anytls-ubuntu.sh"

validate_domain "example.com"
validate_domain "sub.example.co.uk"
validate_ipv4 "1.2.3.4"
validate_ipv4 "255.255.255.255"
validate_server_address "2001:db8::1"
validate_port "1"
validate_port "443"
validate_port "65535"
validate_password "01234567"

for invalid_domain in localhost bad_domain.example 999.1.1.1; do
    if validate_sni "$invalid_domain"; then
        printf 'Unexpected valid SNI: %s\n' "$invalid_domain" >&2
        exit 1
    fi
done

for invalid_ipv4 in 256.1.1.1 1.2.3.999; do
    if validate_ipv4 "$invalid_ipv4"; then
        printf 'Unexpected valid IPv4: %s\n' "$invalid_ipv4" >&2
        exit 1
    fi
done

for invalid_port in 0 65536 abc; do
    if validate_port "$invalid_port"; then
        printf 'Unexpected valid port: %s\n' "$invalid_port" >&2
        exit 1
    fi
done

if validate_password "short"; then
    printf 'Unexpected valid short password.\n' >&2
    exit 1
fi

prepare_release

TEST_DIR="$(new_temp_dir)"
USERS_FILE="${TEST_DIR}/users.json"
PADDING_FILE="${TEST_DIR}/padding.json"
CERT_FILE="${TEST_DIR}/fullchain.pem"
KEY_FILE="${TEST_DIR}/privkey.pem"
CONFIG_FILE="${TEST_DIR}/config.json"
BIN_PATH="$PREPARED_BIN"
export PORT="443"
export LOG_LEVEL="info"

jq -n '[{name:"default", password:"0123456789abcdef"}]' >"$USERS_FILE"
jq -n '["stop=8", "0=30-30", "1=100-400"]' >"$PADDING_FILE"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
    -subj '/CN=example.com' -addext 'subjectAltName=DNS:example.com' \
    -keyout "$KEY_FILE" -out "$CERT_FILE" >/dev/null 2>&1

render_config "$CONFIG_FILE"
"$BIN_PATH" check -c "$CONFIG_FILE"

printf 'All AnyTLS validation tests passed with sing-box %s.\n' "$RELEASE_VERSION"
