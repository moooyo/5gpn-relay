#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export APPLE_RELAY_BASE_DIR="${TEST_ROOT}/opt/apple-relay"
export APPLE_RELAY_CONFIG_DIR="${TEST_ROOT}/etc/apple-relay"
export APPLE_RELAY_STATE_DIR="${TEST_ROOT}/var/lib/apple-relay"
export APPLE_RELAY_UNIT_DIR="${TEST_ROOT}/systemd"
export APPLE_RELAY_LAUNCHER_PATH="${TEST_ROOT}/bin/relayctl"
export APPLE_RELAY_LETSENCRYPT_LIVE_DIR="${TEST_ROOT}/etc/letsencrypt/live"

# shellcheck source=install.sh
source "${ROOT_DIR}/install.sh"

SERVICE_USER="apple-relay-unit-test-$$"

assert_rejected() {
    if "$@"; then
        printf 'Expected command to reject its input: %s\n' "$*" >&2
        exit 1
    fi
}

create_certificate() {
    local certificate="$1"
    local private_key="$2"
    local domain="$3"
    mkdir -p "$(dirname "$certificate")"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -subj "/CN=${domain}" -addext "subjectAltName=DNS:${domain}" \
        -keyout "$private_key" -out "$certificate" >/dev/null 2>&1
}

is_valid_domain relay.example.com
assert_rejected is_valid_domain relay
assert_rejected is_valid_domain '-relay.example.com'
assert_rejected is_valid_domain 'relay_example.com'

is_valid_ip 0.0.0.0
is_valid_ip 127.0.0.1
assert_rejected is_valid_ip ::
assert_rejected is_valid_ip invalid

is_valid_ipv4 1.1.1.1
assert_rejected is_valid_ipv4 10.0.0.1
assert_rejected is_valid_ipv4 2001:4860:4860::8888

is_valid_port 1
is_valid_port 443
is_valid_port 65535
assert_rejected is_valid_port 0
assert_rejected is_valid_port 65536

DOMAIN=relay.example.com
LISTEN_ADDRESS=0.0.0.0
LISTEN_PORT=443
ADMIN_PORT=9901
PUBLIC_IPV4=1.1.1.1
CERT_EMAIL=operator@example.com

mkdir -p "${CONFIG_DIR:?}"
save_environment

DOMAIN=""
PUBLIC_IPV4=""
CERT_EMAIL=""
load_environment

[[ "$DOMAIN" == relay.example.com ]]
[[ "$PUBLIC_IPV4" == 1.1.1.1 ]]
[[ "$CERT_EMAIL" == operator@example.com ]]
[[ "$(stat -c %a "$ENV_FILE")" == 600 ]]

printf '%064d\n' 0 >"$TOKEN_FILE"
render_envoy_config
grep -q 'codec_type: HTTP2' "$ENVOY_CONFIG"
grep -q 'upgrade_type: CONNECT-UDP' "$ENVOY_CONFIG"
grep -q 'name: x-relay-token' "$ENVOY_CONFIG"
assert_rejected grep -q 'codec_type: HTTP3' "$ENVOY_CONFIG"
[[ "$(stat -c %a "$ENVOY_CONFIG")" == 600 ]]

mkdir -p "$TLS_DIR"
create_certificate "${TLS_DIR}/fullchain.pem" "${TLS_DIR}/privkey.pem" "$DOMAIN"
validate_certificate_pair "${TLS_DIR}/fullchain.pem" "${TLS_DIR}/privkey.pem"
now="$(date +%s)"
assert_rejected certificate_is_current_for_domain "${TLS_DIR}/fullchain.pem" "$((now - 172800))"
assert_rejected certificate_is_current_for_domain "${TLS_DIR}/fullchain.pem" "$((now + 172800))"
create_certificate "${TEST_ROOT}/other/fullchain.pem" "${TEST_ROOT}/other/privkey.pem" other.example.com
assert_rejected certificate_is_current_for_domain "${TEST_ROOT}/other/fullchain.pem"
assert_rejected validate_certificate_pair \
    "${TLS_DIR}/fullchain.pem" "${TEST_ROOT}/other/privkey.pem"

certificate_before="$(sha256_file "${TLS_DIR}/fullchain.pem")"
issue_count=0
install_certbot() { :; }
issue_letsencrypt_certificate() { issue_count=$((issue_count + 1)); }
ensure_letsencrypt_certificate
[[ "$issue_count" == 0 ]]
[[ "$(sha256_file "${TLS_DIR}/fullchain.pem")" == "$certificate_before" ]]

lineage="${LETSENCRYPT_LIVE_DIR}/${DOMAIN}"
mkdir -p "$lineage"
cp "${TLS_DIR}/fullchain.pem" "${lineage}/fullchain.pem"
cp "${TLS_DIR}/privkey.pem" "${lineage}/privkey.pem"
rm -f "${TLS_DIR}/fullchain.pem" "${TLS_DIR}/privkey.pem"
ensure_letsencrypt_certificate
[[ "$issue_count" == 0 ]]
validate_certificate_pair "${TLS_DIR}/fullchain.pem" "${TLS_DIR}/privkey.pem"

printf 'invalid\n' >"${TLS_DIR}/fullchain.pem"
printf 'invalid\n' >"${TLS_DIR}/privkey.pem"
printf 'invalid\n' >"${lineage}/fullchain.pem"
printf 'invalid\n' >"${lineage}/privkey.pem"
ensure_letsencrypt_certificate
[[ "$issue_count" == 1 ]]

reissue_events=()
attach_tty() { :; }
require_tty() { :; }
install_gum() { :; }
confirm() { return 0; }
dns_points_to_relay() { return 0; }
issue_letsencrypt_certificate() { reissue_events+=(issue); }
validate_envoy_config() { reissue_events+=(validate); }
systemctl() { reissue_events+=(restart); }
wait_for_relay_ready() { reissue_events+=(ready); }
log_ok() { :; }
reissue_certificate
[[ "${reissue_events[*]}" == "issue validate restart ready" ]]

echo "Unit checks passed."
