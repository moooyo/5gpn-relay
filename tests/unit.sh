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

# shellcheck source=install.sh
source "${ROOT_DIR}/install.sh"

SERVICE_USER="apple-relay-unit-test-$$"

assert_rejected() {
    if "$@"; then
        printf 'Expected command to reject its input: %s\n' "$*" >&2
        exit 1
    fi
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

echo "Unit checks passed."
