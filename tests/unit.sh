#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2317
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

assert_status() {
    local expected="$1"
    shift
    local actual
    if "$@"; then
        actual=0
    else
        actual=$?
    fi
    if [[ "$actual" != "$expected" ]]; then
        printf 'Expected status %s, received %s: %s\n' "$expected" "$actual" "$*" >&2
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

coproc PORT_HOLDER {
    python3 - <<'PY'
import socket
import signal

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(("127.0.0.1", 0))
sock.listen()
print(sock.getsockname()[1], flush=True)
signal.pause()
sock.close()
PY
}
# shellcheck disable=SC2153
port_holder_pid="$PORT_HOLDER_PID"
read -r occupied_port <&"${PORT_HOLDER[0]}"
if bind_error="$(port_is_available tcp 127.0.0.1 "$occupied_port" 2>&1)"; then
    echo "Expected an occupied port to be rejected." >&2
    kill "$port_holder_pid" 2>/dev/null || true
    wait "$port_holder_pid" 2>/dev/null || true
    exit 1
fi
kill "$port_holder_pid" 2>/dev/null || true
wait "$port_holder_pid" 2>/dev/null || true
grep -Fq "TCP 127.0.0.1:${occupied_port} bind failed:" <<<"$bind_error"
grep -Fq '[Errno ' <<<"$bind_error"

time_wait_port="$(python3 - <<'PY'
import socket

listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 0))
listener.listen()
port = listener.getsockname()[1]
client = socket.create_connection(("127.0.0.1", port))
server, _ = listener.accept()
server.shutdown(socket.SHUT_WR)
server.close()
client.recv(1)
client.close()
listener.close()
print(port)
PY
)"
port_is_available tcp 127.0.0.1 "$time_wait_port"

DOMAIN=relay.example.com
LISTEN_ADDRESS=0.0.0.0
LISTEN_PORT=443
ADMIN_PORT=9901
PUBLIC_IPV4=1.1.1.1
CERT_EMAIL=operator@example.com

claim_managed_dir "${CONFIG_DIR:?}" 0700
save_environment

DOMAIN=""
PUBLIC_IPV4=""
CERT_EMAIL=""
load_environment

[[ "$DOMAIN" == relay.example.com ]]
[[ "$PUBLIC_IPV4" == 1.1.1.1 ]]
[[ "$CERT_EMAIL" == operator@example.com ]]
[[ "$(stat -c %a "$ENV_FILE")" == 600 ]]
chmod 0750 "$CONFIG_DIR"
claim_managed_dir "$CONFIG_DIR" 0700
[[ "$(stat -c %a "$CONFIG_DIR")" == 750 ]]
chmod 0770 "$CONFIG_DIR"
assert_rejected is_managed_dir "$CONFIG_DIR"
chmod 0750 "$CONFIG_DIR"

remove_test_dir="${TEST_ROOT}/remove-test"
claim_managed_dir "$remove_test_dir" 0700
printf 'data\n' >"${remove_test_dir}/data"
rm() { return 1; }
assert_status 1 remove_managed_dir "$remove_test_dir"
unset -f rm
[[ ! -e "$remove_test_dir" ]]
remove_test_tombstone="$(find "$TEST_ROOT" -maxdepth 1 -type d -name 'remove-test.removing.*' -print -quit)"
[[ -n "$remove_test_tombstone" ]]
is_managed_dir "$remove_test_tombstone"
rm -rf -- "$remove_test_tombstone"

DNS_CURL_LOG="${TEST_ROOT}/dns-curl.log"
DNS_TEST_MODE=""
curl() {
    local arguments="$*"
    local record_type="A"
    [[ "$arguments" == *'type=AAAA'* ]] && record_type="AAAA"
    printf '%s\n' "$arguments" >>"$DNS_CURL_LOG"

    case "${DNS_TEST_MODE}:${record_type}" in
        match:A|aaaa_timeout:A|has_aaaa:A|http_503:AAAA)
            printf '{"Status":0,"Answer":[{"type":1,"data":"%s"}]}\n' "$PUBLIC_IPV4"
            ;;
        match:AAAA|wrong_a:AAAA|propagate:AAAA)
            printf '{"Status":0}\n'
            ;;
        wrong_a:A)
            printf '{"Status":0,"Answer":[{"type":1,"data":"8.8.8.8"}]}\n'
            ;;
        has_aaaa:AAAA)
            printf '{"Status":0,"Answer":[{"type":28,"data":"2001:db8::1"}]}\n'
            ;;
        aaaa_timeout:AAAA)
            printf 'curl: (28) Operation timed out\n' >&2
            return 28
            ;;
        http_503:A)
            printf 'curl: (22) The requested URL returned error: 503\n' >&2
            return 22
            ;;
        invalid_json:A)
            printf 'not-json\n'
            ;;
        servfail:A)
            printf '{"Status":2}\n'
            ;;
        nxdomain:A|nxdomain:AAAA)
            printf '{"Status":3}\n'
            ;;
        propagate:A)
            local a_query_count
            a_query_count="$(grep -c 'type=A$' "$DNS_CURL_LOG" || true)"
            if (( a_query_count == 1 )); then
                printf '{"Status":0,"Answer":[{"type":1,"data":"8.8.8.8"}]}\n'
            else
                printf '{"Status":0,"Answer":[{"type":1,"data":"%s"}]}\n' "$PUBLIC_IPV4"
            fi
            ;;
        *)
            printf 'Unexpected DNS test mode: %s\n' "${DNS_TEST_MODE}:${record_type}" >&2
            return 99
            ;;
    esac
}

: >"$DNS_CURL_LOG"
DNS_TEST_MODE=match
assert_status 0 dns_points_to_relay
[[ "$DNS_LAST_DETAIL" == "A=${PUBLIC_IPV4}, AAAA=none" ]]
[[ "$(grep -c 'type=A$' "$DNS_CURL_LOG")" == 1 ]]
[[ "$(grep -c 'type=AAAA$' "$DNS_CURL_LOG")" == 1 ]]

: >"$DNS_CURL_LOG"
DNS_TEST_MODE=wrong_a
assert_status 1 dns_points_to_relay
[[ "$DNS_LAST_DETAIL" == "A=8.8.8.8, AAAA=none" ]]

: >"$DNS_CURL_LOG"
DNS_TEST_MODE=has_aaaa
assert_status 1 dns_points_to_relay
[[ "$DNS_LAST_DETAIL" == "A=${PUBLIC_IPV4}, AAAA=2001:db8::1" ]]

: >"$DNS_CURL_LOG"
DNS_TEST_MODE=aaaa_timeout
assert_status 2 dns_points_to_relay
[[ "$DNS_LAST_ERROR" == *AAAA* ]]
[[ "$DNS_LAST_ERROR" == *'curl exit 28'* ]]
[[ "$DNS_LAST_ERROR" == *'Operation timed out'* ]]

: >"$DNS_CURL_LOG"
DNS_TEST_MODE=http_503
assert_status 2 dns_points_to_relay
[[ "$DNS_LAST_ERROR" == *'curl exit 22'* ]]
[[ "$DNS_LAST_ERROR" == *503* ]]

: >"$DNS_CURL_LOG"
DNS_TEST_MODE=invalid_json
assert_status 2 dns_points_to_relay
[[ "$DNS_LAST_ERROR" == *'invalid JSON'* ]]

: >"$DNS_CURL_LOG"
DNS_TEST_MODE=servfail
assert_status 2 dns_points_to_relay
[[ "$DNS_LAST_ERROR" == *'Status=2 (SERVFAIL)'* ]]

: >"$DNS_CURL_LOG"
DNS_TEST_MODE=nxdomain
assert_status 1 dns_points_to_relay
[[ "$DNS_LAST_DETAIL" == 'A=NXDOMAIN, AAAA=NXDOMAIN' ]]

show_dns_instructions() { :; }
confirm() { return 0; }
log_info() { :; }
log_ok() { :; }
log_warn() { :; }
: >"$DNS_CURL_LOG"
DNS_TEST_MODE=propagate
DNS_POLL_INTERVAL_SECONDS=0
wait_for_dns
DNS_POLL_INTERVAL_SECONDS=5
[[ "$(grep -c 'type=A$' "$DNS_CURL_LOG")" == 2 ]]
[[ "$(grep -c 'type=AAAA$' "$DNS_CURL_LOG")" == 2 ]]

dns_now_epoch() { printf '104\n'; }
[[ "$(dns_timeout_before_deadline 107)" == 3 ]]
assert_status 1 dns_timeout_before_deadline 104
dns_now_epoch() { date +%s; }
unset -f curl

printf '%064d\n' 0 >"$TOKEN_FILE"
render_envoy_config
grep -q 'codec_type: HTTP2' "$ENVOY_CONFIG"
grep -q 'upgrade_type: CONNECT-UDP' "$ENVOY_CONFIG"
grep -q 'name: x-relay-token' "$ENVOY_CONFIG"
assert_rejected grep -q 'codec_type: HTTP3' "$ENVOY_CONFIG"
[[ "$(stat -c %a "$ENVOY_CONFIG")" == 600 ]]

cp -a "$ENV_FILE" "${TEST_ROOT}/relay.env.saved"
cp -a "$TOKEN_FILE" "${TEST_ROOT}/token.saved"
claim_managed_dir "$BASE_DIR" 0755
mkdir -p "${BASE_DIR}/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$ENVOY_BIN"
chmod 0755 "$ENVOY_BIN"
assess_existing_configuration
[[ "$REUSE_EXISTING_CONFIG" == 1 ]]
[[ "$EXISTING_TOKEN_INVALID" == 0 ]]
[[ "$REBUILD_EXISTING_ENVOY_CONFIG" == 0 ]]

printf '%064d\n' 1 >"$TOKEN_FILE"
assess_existing_configuration
[[ "$REUSE_EXISTING_CONFIG" == 1 ]]
[[ "$EXISTING_TOKEN_INVALID" == 0 ]]
[[ "$REBUILD_EXISTING_ENVOY_CONFIG" == 1 ]]
rm -f "$TOKEN_FILE"
cp -a "${TEST_ROOT}/token.saved" "$TOKEN_FILE"

printf 'invalid token\n' >"$TOKEN_FILE"
assess_existing_configuration
[[ "$REUSE_EXISTING_CONFIG" == 1 ]]
[[ "$EXISTING_TOKEN_INVALID" == 1 ]]
[[ "$REBUILD_EXISTING_ENVOY_CONFIG" == 1 ]]
rm -f "$TOKEN_FILE"
cp -a "${TEST_ROOT}/token.saved" "$TOKEN_FILE"

printf 'DOMAIN=invalid\n' >"$ENV_FILE"
assert_status 1 assess_existing_configuration
[[ "$EXISTING_CONFIG_INVALID" == 1 ]]
[[ -n "$EXISTING_CONFIG_ERROR" ]]
rm -f "$ENV_FILE"
cp -a "${TEST_ROOT}/relay.env.saved" "$ENV_FILE"
load_environment
EXISTING_CONFIG_INVALID=0

rm -f "$ENV_FILE"
printf 'invalid token\n' >"$TOKEN_FILE"
assert_status 1 validate_existing_project_configuration
[[ "$EXISTING_CONFIG_INVALID" == 1 ]]
[[ "$EXISTING_TOKEN_INVALID" == 1 ]]
rm -f "$TOKEN_FILE"
cp -a "${TEST_ROOT}/relay.env.saved" "$ENV_FILE"
cp -a "${TEST_ROOT}/token.saved" "$TOKEN_FILE"
load_environment
EXISTING_CONFIG_INVALID=0

mkdir -p "${TEST_ROOT}/external-tls"
ln -s "${TEST_ROOT}/external-tls" "$TLS_DIR"
if tls_layout_output="$(assert_existing_tls_layout_safe 2>&1)"; then
    echo "Expected a TLS directory symlink to be rejected." >&2
    exit 1
fi
[[ "$tls_layout_output" == *'unsafe TLS configuration directory'* ]]
rm -f "$TLS_DIR"
mv "$ENVOY_CONFIG" "${TEST_ROOT}/envoy.yaml.saved"
mkdir -p "${TEST_ROOT}/external-envoy"
ln -s "${TEST_ROOT}/external-envoy" "$ENVOY_CONFIG"
if envoy_path_output="$(assess_existing_configuration 2>&1)"; then
    echo "Expected an Envoy configuration symlink to be rejected." >&2
    exit 1
fi
[[ "$envoy_path_output" == *'unsafe generated Envoy configuration path'* ]]
rm -f "$ENVOY_CONFIG"
mv "${TEST_ROOT}/envoy.yaml.saved" "$ENVOY_CONFIG"

(
    CONFIG_DIR="${TEST_ROOT}/partial-config"
    ENV_FILE="${CONFIG_DIR}/relay.env"
    TOKEN_FILE="${CONFIG_DIR}/token"
    TLS_DIR="${CONFIG_DIR}/tls"
    mkdir -p "$TLS_DIR"
    printf 'invalid environment\n' >"$ENV_FILE"
    printf '%064d\n' 0 >"$TOKEN_FILE"
    printf 'preserve TLS\n' >"${TLS_DIR}/sentinel"
    PREVIOUS_INSTALLATION_DETECTED=0
    EXISTING_CONFIG_INVALID=1
    EXISTING_CONFIG_ERROR="synthetic invalid environment"
    EXISTING_TOKEN_INVALID=0
    remove_previous_runtime_installation() { :; }
    claim_project_dirs() { :; }
    install_gum() { :; }
    publish_manager() { :; }
    install_envoy() { :; }
    prepare_runtime_installation
    [[ ! -e "$ENV_FILE" ]]
    [[ -s "$TOKEN_FILE" ]]
    [[ "$(cat "${TLS_DIR}/sentinel")" == 'preserve TLS' ]]
)

SYSTEMCTL_LOG="${TEST_ROOT}/systemctl.log"
systemctl() {
    printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
    return 0
}
: >"$SYSTEMCTL_LOG"
install_systemd_units
grep -Fqx \
    "ExecStart=${ENVOY_BIN} -c ${ENVOY_CONFIG} --log-level info --disable-hot-restart" \
    "$SERVICE_UNIT"
grep -Fqx 'StartLimitIntervalSec=60s' "$SERVICE_UNIT"
grep -Fqx 'StartLimitBurst=5' "$SERVICE_UNIT"
assert_rejected grep -q 'enable --now apple-relay-renew.timer' "$SYSTEMCTL_LOG"

READY_CURL_LOG="${TEST_ROOT}/ready-curl.log"
READY_SYSTEMD_STATE=running
curl() {
    printf 'call\n' >>"$READY_CURL_LOG"
    printf 'LIVE\n'
}
systemctl() {
    case "$1" in
        is-failed) return 1 ;;
        show)
            if [[ "$*" == *'property=ActiveState'* ]]; then
                printf 'active\n'
            else
                printf '%s\n' "$READY_SYSTEMD_STATE"
            fi
            ;;
        *) return 0 ;;
    esac
}
: >"$READY_CURL_LOG"
# shellcheck disable=SC2218
wait_for_relay_ready
[[ "$(wc -l <"$READY_CURL_LOG")" == 2 ]]
READY_SYSTEMD_STATE=auto-restart
assert_status 1 wait_for_relay_ready
[[ "$RELAY_READY_ERROR" == *auto-restart* ]]
unset -f curl

PROCESS_TREE_CHILD_FILE="${TEST_ROOT}/process-tree-child"
(
    sleep 30 &
    printf '%s\n' "$!" >"$PROCESS_TREE_CHILD_FILE"
    wait
) &
process_tree_parent=$!
while [[ ! -s "$PROCESS_TREE_CHILD_FILE" ]]; do
    sleep 0.01
done
process_tree_child="$(cat "$PROCESS_TREE_CHILD_FILE")"
INSTALL_APPLY_PID="$process_tree_parent"
interrupt_install_transaction TERM
wait "$process_tree_parent" 2>/dev/null || true
INSTALL_APPLY_PID=""
if kill -0 "$process_tree_child" 2>/dev/null; then
    process_tree_state="$(ps -o stat= -p "$process_tree_child" 2>/dev/null || true)"
    [[ "$process_tree_state" == Z* ]]
fi
INSTALL_INTERRUPTED_SIGNAL=""

RESTART_TEST_MODE=""
relay_journal_cursor() { printf 'synthetic-cursor\n'; }
show_relay_journal_since() { printf 'synthetic journal line\n' >&2; }
wait_for_relay_ready() {
    if [[ "$RESTART_TEST_MODE" == "ready" ]]; then
        return 0
    fi
    RELAY_READY_ERROR="synthetic readiness error"
    return 1
}
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }
systemctl() {
    printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
    case "$1" in
        reset-failed|stop) return 0 ;;
        restart)
            [[ "$RESTART_TEST_MODE" != "restart-fail" ]] || return 7
            return 0
            ;;
        show)
            if [[ "$*" == *'property=ActiveState'* ]]; then
                [[ "$RESTART_TEST_MODE" == "restart-fail" ]] && printf 'failed\n' || printf 'active\n'
            else
                [[ "$RESTART_TEST_MODE" == "restart-fail" ]] && printf 'failed\n' || printf 'running\n'
            fi
            return 0
            ;;
        *) return 0 ;;
    esac
}

: >"$SYSTEMCTL_LOG"
RESTART_TEST_MODE=restart-fail
if restart_output="$(restart_relay_service 2>&1)"; then
    echo "Expected an immediate systemctl restart failure." >&2
    exit 1
fi
[[ "$restart_output" == *'exit 7'* ]]
[[ "$restart_output" == *'synthetic journal line'* ]]
grep -q '^stop apple-relay.service$' "$SYSTEMCTL_LOG"

: >"$SYSTEMCTL_LOG"
RESTART_TEST_MODE=readiness-fail
if restart_output="$(restart_relay_service 2>&1)"; then
    echo "Expected a readiness failure." >&2
    exit 1
fi
[[ "$restart_output" == *'synthetic readiness error'* ]]
[[ "$restart_output" == *'synthetic journal line'* ]]
grep -q '^stop apple-relay.service$' "$SYSTEMCTL_LOG"

: >"$SYSTEMCTL_LOG"
RESTART_TEST_MODE=ready
# shellcheck disable=SC2218
restart_relay_service
assert_rejected grep -q '^stop apple-relay.service$' "$SYSTEMCTL_LOG"

ROLLBACK_SYSTEMCTL_PHASE=snapshot
ROLLBACK_SERVICES_STOPPED=0
ROLLBACK_UNIT_FILE_STATE=enabled
systemctl() {
    printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
    case "$1" in
        is-active)
            [[ "$ROLLBACK_SYSTEMCTL_PHASE" == "snapshot" \
                && "$ROLLBACK_SERVICES_STOPPED" == 0 ]]
            ;;
        is-enabled)
            if [[ "$ROLLBACK_SYSTEMCTL_PHASE" == "snapshot" ]]; then
                printf 'enabled\n'
                return 0
            fi
            return 1
            ;;
        stop)
            ROLLBACK_SERVICES_STOPPED=1
            return 0
            ;;
        show)
            if [[ "$*" == *'property=LoadState'* ]]; then
                printf 'loaded\n'
            elif [[ "$*" == *'property=FragmentPath'* ]]; then
                case "$*" in
                    *apple-relay-renew.timer*) printf '%s\n' "$RENEW_TIMER_UNIT" ;;
                    *apple-relay-renew.service*) printf '%s\n' "$RENEW_SERVICE_UNIT" ;;
                    *) printf '%s\n' "$SERVICE_UNIT" ;;
                esac
            elif [[ "$*" == *'property=ActiveState'* ]]; then
                [[ "$ROLLBACK_SERVICES_STOPPED" == 0 ]] \
                    && printf 'active\n' || printf 'inactive\n'
            elif [[ "$*" == *'property=UnitFileState'* ]]; then
                printf '%s\n' "$ROLLBACK_UNIT_FILE_STATE"
            fi
            return 0
            ;;
        disable)
            ROLLBACK_UNIT_FILE_STATE=disabled
            return 0
            ;;
        enable)
            if [[ "$*" == *'--runtime'* ]]; then
                ROLLBACK_UNIT_FILE_STATE=enabled-runtime
            else
                ROLLBACK_UNIT_FILE_STATE=enabled
            fi
            return 0
            ;;
        reset-failed|restart|start|daemon-reload)
            return 0
            ;;
        *) return 0 ;;
    esac
}
env_before="$(sha256_file "$ENV_FILE")"
token_before="$(sha256_file "$TOKEN_FILE")"
config_before="$(sha256_file "$ENVOY_CONFIG")"
unit_before="$(sha256_file "$SERVICE_UNIT")"
claim_managed_dir "$BASE_DIR" 0755
mkdir -p "${BASE_DIR}/bin"
printf 'old runtime\n' >"$BACKEND_PATH"
chmod 0755 "$BACKEND_PATH"
{
    printf '#!/usr/bin/env bash\n'
    printf 'BACKEND="%s"\n' "$BACKEND_PATH"
} | write_atomic "$LAUNCHER_PATH" 755
launcher_before="$(sha256_file "$LAUNCHER_PATH")"
cp -a "$SERVICE_UNIT" "${TEST_ROOT}/apple-relay.service.saved"
printf 'unrecognized unit\n' | write_atomic "$SERVICE_UNIT" 644
if conflict_output="$(detect_previous_installation 2>&1)"; then
    echo "Expected an unrecognized unit collision to be rejected." >&2
    exit 1
fi
[[ "$conflict_output" == *'unrecognized systemd unit'* ]]
rm -f "$SERVICE_UNIT"
cp -a "${TEST_ROOT}/apple-relay.service.saved" "$SERVICE_UNIT"
detect_previous_installation
[[ "$PREVIOUS_INSTALLATION_DETECTED" == 1 ]]
INSTALL_BASE_PREEXISTED=1
INSTALL_CONFIG_PREEXISTED=1
INSTALL_STATE_PREEXISTED=1
: >"$SYSTEMCTL_LOG"
snapshot_install_state
ROLLBACK_SYSTEMCTL_PHASE=remove
remove_previous_runtime_installation
[[ ! -e "$BASE_DIR" ]]
[[ ! -e "$LAUNCHER_PATH" ]]
[[ ! -e "$SERVICE_UNIT" ]]
[[ "$(sha256_file "$ENV_FILE")" == "$env_before" ]]
[[ "$(sha256_file "$TOKEN_FILE")" == "$token_before" ]]
[[ "$(sha256_file "$ENVOY_CONFIG")" == "$config_before" ]]
claim_managed_dir "$BASE_DIR" 0755
printf 'new runtime\n' >"${BASE_DIR}/new-file"
printf 'broken environment\n' >"$ENV_FILE"
printf 'broken token\n' >"$TOKEN_FILE"
printf 'broken config\n' >"$ENVOY_CONFIG"
printf 'broken unit\n' >"$SERVICE_UNIT"
mkdir -p "$TLS_DIR"
printf 'new TLS data\n' >"${TLS_DIR}/new-file"
ROLLBACK_SYSTEMCTL_PHASE=restore
restore_install_state
[[ "$(sha256_file "$ENV_FILE")" == "$env_before" ]]
[[ "$(sha256_file "$TOKEN_FILE")" == "$token_before" ]]
[[ "$(sha256_file "$ENVOY_CONFIG")" == "$config_before" ]]
[[ "$(sha256_file "$SERVICE_UNIT")" == "$unit_before" ]]
[[ "$(sha256_file "$LAUNCHER_PATH")" == "$launcher_before" ]]
[[ "$(cat "$BACKEND_PATH")" == 'old runtime' ]]
[[ ! -e "${TLS_DIR}/new-file" ]]
[[ -z "$INSTALL_BACKUP_DIR" ]]
grep -q '^stop apple-relay-renew.timer apple-relay-renew.service$' "$SYSTEMCTL_LOG"
grep -q '^stop apple-relay-renew.timer apple-relay-renew.service apple-relay.service$' "$SYSTEMCTL_LOG"
grep -q '^restart apple-relay.service$' "$SYSTEMCTL_LOG"
grep -q '^start apple-relay-renew.timer$' "$SYSTEMCTL_LOG"
: >"$SYSTEMCTL_LOG"
restore_unit_enable_state apple-relay.service enabled-runtime
grep -q '^enable --runtime apple-relay.service$' "$SYSTEMCTL_LOG"

(
    BASE_DIR="${TEST_ROOT}/fresh/opt/apple-relay"
    CONFIG_DIR="${TEST_ROOT}/fresh/etc/apple-relay"
    STATE_DIR="${TEST_ROOT}/fresh/var/lib/apple-relay"
    UNIT_DIR="${TEST_ROOT}/fresh/systemd"
    BACKEND_PATH="${BASE_DIR}/relayctl"
    LAUNCHER_PATH="${TEST_ROOT}/fresh/bin/relayctl"
    ENV_FILE="${CONFIG_DIR}/relay.env"
    TOKEN_FILE="${CONFIG_DIR}/token"
    ENVOY_CONFIG="${CONFIG_DIR}/envoy.yaml"
    TLS_DIR="${CONFIG_DIR}/tls"
    SERVICE_UNIT="${UNIT_DIR}/apple-relay.service"
    RENEW_SERVICE_UNIT="${UNIT_DIR}/apple-relay-renew.service"
    RENEW_TIMER_UNIT="${UNIT_DIR}/apple-relay-renew.timer"
    GUM_BIN="${BASE_DIR}/bin/gum"
    ENVOY_BIN="${BASE_DIR}/bin/envoy"
    SERVICE_USER_MARKER="${STATE_DIR}/service-user.created"
    INSTALL_BACKUP_DIR=""
    INSTALL_BASE_PREEXISTED=0
    INSTALL_CONFIG_PREEXISTED=0
    INSTALL_STATE_PREEXISTED=0
    systemctl() {
        case "$1" in
            show)
                if [[ "$*" == *'property=LoadState'* ]]; then
                    printf 'not-found\n'
                elif [[ "$*" == *'property=ActiveState'* ]]; then
                    printf 'inactive\n'
                fi
                ;;
            *) return 0 ;;
        esac
    }
    claim_project_dirs
    snapshot_install_state
    printf 'new runtime\n' >"$BACKEND_PATH"
    printf 'new config\n' >"$ENV_FILE"
    printf 'new state\n' >"${STATE_DIR}/new-state"
    printf 'new unit\n' | write_atomic "$SERVICE_UNIT" 644
    printf 'new launcher\n' | write_atomic "$LAUNCHER_PATH" 755
    restore_install_state
    [[ ! -e "$BASE_DIR" ]]
    [[ ! -e "$CONFIG_DIR" ]]
    [[ ! -e "$STATE_DIR" ]]
    [[ ! -e "$SERVICE_UNIT" ]]
    [[ ! -e "$LAUNCHER_PATH" ]]
)

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
[[ "$issue_count" == 1 ]]
[[ "$(sha256_file "${TLS_DIR}/fullchain.pem")" == "$certificate_before" ]]

lineage="${LETSENCRYPT_LIVE_DIR}/${DOMAIN}"
mkdir -p "$lineage"
cp "${TLS_DIR}/fullchain.pem" "${lineage}/fullchain.pem"
cp "${TLS_DIR}/privkey.pem" "${lineage}/privkey.pem"
rm -f "${TLS_DIR}/fullchain.pem" "${TLS_DIR}/privkey.pem"
ensure_letsencrypt_certificate
[[ "$issue_count" == 1 ]]
validate_certificate_pair "${TLS_DIR}/fullchain.pem" "${TLS_DIR}/privkey.pem"
certificate_inode="$(stat -c %i "${TLS_DIR}/fullchain.pem")"
ensure_letsencrypt_certificate
[[ "$issue_count" == 1 ]]
[[ "$(stat -c %i "${TLS_DIR}/fullchain.pem")" == "$certificate_inode" ]]

printf 'invalid\n' >"${TLS_DIR}/fullchain.pem"
printf 'invalid\n' >"${TLS_DIR}/privkey.pem"
printf 'invalid\n' >"${lineage}/fullchain.pem"
printf 'invalid\n' >"${lineage}/privkey.pem"
ensure_letsencrypt_certificate
[[ "$issue_count" == 2 ]]

(
    apply_events=()
    prepare_runtime_installation() { apply_events+=(prepare); }
    save_environment() { apply_events+=(save); }
    ensure_letsencrypt_certificate() { apply_events+=(certificate); }
    render_envoy_config() { apply_events+=(render); }
    secure_runtime_files() { apply_events+=(secure); }
    validate_envoy_config() { apply_events+=(validate); }
    install_systemd_units() { apply_events+=(units); }
    restart_relay_service() { apply_events+=(restart); }
    systemctl() { apply_events+=(timer); }

    REUSE_EXISTING_CONFIG=1
    REBUILD_EXISTING_ENVOY_CONFIG=0
    apply_install_configuration
    [[ "${apply_events[*]}" == "prepare certificate secure validate units restart timer" ]]

    apply_events=()
    REUSE_EXISTING_CONFIG=0
    REBUILD_EXISTING_ENVOY_CONFIG=0
    apply_install_configuration
    [[ "${apply_events[*]}" == "prepare save certificate render secure validate units restart timer" ]]
)

reissue_events=()
attach_tty() { :; }
require_tty() { :; }
install_gum() { :; }
confirm() { return 0; }
dns_points_to_relay() { return 0; }
issue_letsencrypt_certificate() { reissue_events+=(issue); }
validate_envoy_config() { reissue_events+=(validate); }
restart_relay_service() { reissue_events+=(restart ready); }
log_ok() { :; }
reissue_certificate
[[ "${reissue_events[*]}" == "issue validate restart ready" ]]

echo "Unit checks passed."
