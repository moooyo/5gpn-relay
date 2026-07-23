#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

readonly PROJECT_VERSION="0.1.0"
readonly GUM_VERSION="0.17.0"
readonly ENVOY_VERSION="1.39.0"
readonly ENVOY_SHA256_X86_64="4409dadc87931d8f8676314cbd83071cb65125fb4feac3f6335800580dfa9218"
readonly ENVOY_SHA256_AARCH64="ee53a4f5375566f15944dc9cb03afb1fc228df38f61737c677f139213215afcf"
readonly SOURCE_URL="https://raw.githubusercontent.com/moooyo/5gpn-relay/main/install.sh"
readonly OWNERSHIP_MARKER=".apple-relay-managed"
readonly OWNERSHIP_VALUE="5gpn-relay:v1"

BASE_DIR="${APPLE_RELAY_BASE_DIR:-/opt/apple-relay}"
CONFIG_DIR="${APPLE_RELAY_CONFIG_DIR:-/etc/apple-relay}"
STATE_DIR="${APPLE_RELAY_STATE_DIR:-/var/lib/apple-relay}"
UNIT_DIR="${APPLE_RELAY_UNIT_DIR:-/etc/systemd/system}"
BACKEND_PATH="${BASE_DIR}/relayctl"
LAUNCHER_PATH="${APPLE_RELAY_LAUNCHER_PATH:-/usr/local/bin/relayctl}"
ENV_FILE="${CONFIG_DIR}/relay.env"
TOKEN_FILE="${CONFIG_DIR}/token"
ENVOY_CONFIG="${CONFIG_DIR}/envoy.yaml"
TLS_DIR="${CONFIG_DIR}/tls"
LETSENCRYPT_LIVE_DIR="${APPLE_RELAY_LETSENCRYPT_LIVE_DIR:-/etc/letsencrypt/live}"
SERVICE_UNIT="${UNIT_DIR}/apple-relay.service"
RENEW_SERVICE_UNIT="${UNIT_DIR}/apple-relay-renew.service"
RENEW_TIMER_UNIT="${UNIT_DIR}/apple-relay-renew.timer"
GUM_BIN="${BASE_DIR}/bin/gum"
ENVOY_BIN="${BASE_DIR}/bin/envoy"
SERVICE_USER="apple-relay"
SERVICE_USER_MARKER="${STATE_DIR}/service-user.created"

DOMAIN=""
LISTEN_ADDRESS="0.0.0.0"
LISTEN_PORT="443"
ADMIN_PORT="9901"
PUBLIC_IPV4=""
CERT_EMAIL=""

DNS_QUERY_CONNECT_TIMEOUT_SECONDS=5
DNS_QUERY_MAX_TIME_SECONDS=15
DNS_PROPAGATION_TIMEOUT_SECONDS=300
DNS_POLL_INTERVAL_SECONDS=5
DNS_MAX_CONSECUTIVE_ERRORS=3

DNS_QUERY_STATE=""
DNS_QUERY_RECORDS=""
DNS_QUERY_ERROR=""
DNS_A_STATE=""
DNS_A_RECORDS=""
DNS_AAAA_STATE=""
DNS_AAAA_RECORDS=""
DNS_LAST_DETAIL=""
DNS_LAST_ERROR=""

RELAY_READY_TIMEOUT_SECONDS=15
RELAY_READY_ERROR=""

INSTALL_BACKUP_DIR=""
INSTALL_SERVICE_WAS_ACTIVE=0
INSTALL_TIMER_WAS_ACTIVE=0
INSTALL_RENEW_SERVICE_WAS_ACTIVE=0
INSTALL_SERVICE_ENABLE_STATE=""
INSTALL_TIMER_ENABLE_STATE=""
INSTALL_SERVICE_ACTIVE_STATE=""
INSTALL_TIMER_ACTIVE_STATE=""
INSTALL_RENEW_ACTIVE_STATE=""
INSTALL_SERVICE_USER_EXISTED=0
INSTALL_SERVICE_GROUP_EXISTED=0
INSTALL_BASE_PREEXISTED=0
INSTALL_CONFIG_PREEXISTED=0
INSTALL_STATE_PREEXISTED=0
INSTALL_BOOTSTRAP_CLEANUP_ACTIVE=0
INSTALL_APPLY_PID=""
INSTALL_INTERRUPTED_SIGNAL=""
INSTALL_PROCESS_TREE_PIDS=()
INSTALL_PROCESS_TREE_IDENTITIES=()

PREVIOUS_INSTALLATION_DETECTED=0
EXISTING_CONFIG_INVALID=0
EXISTING_CONFIG_ERROR=""
EXISTING_TOKEN_INVALID=0
EXISTING_TOKEN_ERROR=""
REUSE_EXISTING_CONFIG=0
REBUILD_EXISTING_ENVOY_CONFIG=0
ENVIRONMENT_ERROR=""

log_info() {
    if have_gum; then
        "$GUM_BIN" log --level info -- "$*"
    else
        printf '[INFO] %s\n' "$*"
    fi
}

log_ok() {
    if have_gum; then
        "$GUM_BIN" log --level info -- "OK: $*"
    else
        printf '[OK] %s\n' "$*"
    fi
}

log_warn() {
    if have_gum; then
        "$GUM_BIN" log --level warn -- "$*"
    else
        printf '[WARN] %s\n' "$*" >&2
    fi
}

log_error() {
    if have_gum; then
        "$GUM_BIN" log --level error -- "$*" >&2
    else
        printf '[ERROR] %s\n' "$*" >&2
    fi
}

die() {
    log_error "$*"
    exit 1
}

have_gum() {
    [[ -x "$GUM_BIN" ]]
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this command as root."
}

require_tty() {
    [[ -t 0 && -t 1 ]] || die "This command requires an interactive terminal."
}

attach_tty() {
    if [[ ! -t 0 && -r /dev/tty ]]; then
        exec </dev/tty
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

is_managed_dir() {
    local path="$1"
    local marker="${path}/${OWNERSHIP_MARKER}"
    local path_mode marker_mode
    [[ -d "$path" && ! -L "$path" && -f "$marker" && ! -L "$marker" ]] || return 1
    [[ "$(stat -c %u "$path" 2>/dev/null)" == "0" ]] || return 1
    [[ "$(stat -c %u "$marker" 2>/dev/null)" == "0" ]] || return 1
    path_mode="$(stat -c %a "$path" 2>/dev/null)"
    marker_mode="$(stat -c %a "$marker" 2>/dev/null)"
    [[ "$path_mode" =~ ^[0-7]{3,4}$ && "$marker_mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$path_mode & 022) == 0 && (8#$marker_mode & 022) == 0 )) || return 1
    [[ "$(cat "$marker" 2>/dev/null)" == "$OWNERSHIP_VALUE" ]]
}

claim_managed_dir() {
    local path="$1"
    local mode="$2"
    local marker="${path}/${OWNERSHIP_MARKER}"
    if [[ -L "$path" || (-e "$path" && ! -d "$path") ]]; then
        die "Refusing unsafe project directory: ${path}"
    fi
    if [[ ! -d "$path" ]]; then
        mkdir -p "$path"
    elif ! is_managed_dir "$path"; then
        die "Refusing to claim an existing unowned directory: ${path}"
    else
        return 0
    fi
    if [[ ! -f "$marker" ]]; then
        printf '%s\n' "$OWNERSHIP_VALUE" >"$marker"
    fi
    chown root:root "$path" "$marker"
    chmod "$mode" "$path"
    chmod 0600 "$marker"
    is_managed_dir "$path" || die "Could not establish ownership for ${path}."
}

claim_project_dirs() {
    claim_managed_dir "$BASE_DIR" 0755
    claim_managed_dir "$CONFIG_DIR" 0700
    claim_managed_dir "$STATE_DIR" 0700
}

remove_managed_dir() {
    local path="$1"
    local tombstone="" attempt
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        return 0
    fi
    if ! is_managed_dir "$path"; then
        log_warn "Preserving unowned or unsafe directory: ${path}"
        return 1
    fi
    for attempt in {1..10}; do
        tombstone="${path}.removing.$$.${RANDOM}.${attempt}"
        [[ ! -e "$tombstone" && ! -L "$tombstone" ]] || continue
        if mv -T -- "$path" "$tombstone"; then
            break
        fi
        tombstone=""
    done
    if [[ -z "$tombstone" || -e "$path" || -L "$path" ]]; then
        log_error "Could not move the managed directory out of service before removal: ${path}"
        return 1
    fi
    if ! rm -rf -- "$tombstone"; then
        log_error "The managed directory was detached but could not be fully removed: ${tombstone}"
        return 1
    fi
}

random_token() {
    if command_exists openssl; then
        openssl rand -hex 32
    else
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

sha256_file() {
    if command_exists sha256sum; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

is_valid_domain() {
    local value="$1"
    [[ ${#value} -le 253 ]] || return 1
    [[ "$value" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

is_valid_ip() {
    local value="$1"
    if [[ "$value" == "0.0.0.0" ]]; then
        return 0
    fi
    command_exists python3 || return 1
    python3 - "$value" <<'PY'
import ipaddress
import sys

try:
    value = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

if value.version != 4:
    raise SystemExit(1)
PY
}

is_valid_ipv4() {
    local value="$1"
    command_exists python3 || return 1
    python3 - "$value" <<'PY'
import ipaddress
import sys

try:
    value = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

if value.version != 4 or not value.is_global:
    raise SystemExit(1)
PY
}

is_valid_port() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 ))
}

write_atomic() {
    local destination="$1"
    local mode="$2"
    local temporary
    mkdir -p "$(dirname "$destination")"
    temporary="$(mktemp "${destination}.tmp.XXXXXX")"
    cat >"$temporary"
    chmod "$mode" "$temporary"
    mv -f "$temporary" "$destination"
}

shell_quote() {
    printf '%q' "$1"
}

save_environment() {
    {
        printf 'DOMAIN=%s\n' "$(shell_quote "$DOMAIN")"
        printf 'LISTEN_ADDRESS=%s\n' "$(shell_quote "$LISTEN_ADDRESS")"
        printf 'LISTEN_PORT=%s\n' "$(shell_quote "$LISTEN_PORT")"
        printf 'ADMIN_PORT=%s\n' "$(shell_quote "$ADMIN_PORT")"
        printf 'PUBLIC_IPV4=%s\n' "$(shell_quote "$PUBLIC_IPV4")"
        printf 'CERT_EMAIL=%s\n' "$(shell_quote "$CERT_EMAIL")"
    } | write_atomic "$ENV_FILE" 600
}

validate_saved_environment() {
    ENVIRONMENT_ERROR=""
    if [[ ! -f "$ENV_FILE" || -L "$ENV_FILE" \
        || "$(stat -c %u "$ENV_FILE" 2>/dev/null)" != "0" ]]; then
        ENVIRONMENT_ERROR="The saved environment file is not a safe root-owned regular file."
        return 1
    fi
    local env_mode
    env_mode="$(stat -c %a "$ENV_FILE" 2>/dev/null)"
    if [[ ! "$env_mode" =~ ^[0-7]{3,4}$ ]] || (( (8#$env_mode & 022) != 0 )); then
        ENVIRONMENT_ERROR="The saved environment file is writable by a non-root user."
        return 1
    fi

    DOMAIN=""
    LISTEN_ADDRESS=""
    LISTEN_PORT=""
    ADMIN_PORT=""
    PUBLIC_IPV4=""
    CERT_EMAIL=""
    # The file is root-owned, mode 0600, and every value is written with shell escaping.
    # shellcheck disable=SC1090
    if ! source "$ENV_FILE"; then
        ENVIRONMENT_ERROR="The saved environment file could not be parsed."
        return 1
    fi
    if ! is_valid_domain "$DOMAIN"; then
        ENVIRONMENT_ERROR="The saved relay domain is invalid."
        return 1
    fi
    if ! is_valid_ip "$LISTEN_ADDRESS"; then
        ENVIRONMENT_ERROR="The saved listen address is invalid."
        return 1
    fi
    if ! is_valid_port "$LISTEN_PORT"; then
        ENVIRONMENT_ERROR="The saved listen port is invalid."
        return 1
    fi
    if ! is_valid_port "$ADMIN_PORT"; then
        ENVIRONMENT_ERROR="The saved admin port is invalid."
        return 1
    fi
    if ! is_valid_ipv4 "$PUBLIC_IPV4"; then
        ENVIRONMENT_ERROR="The saved public IPv4 address is invalid."
        return 1
    fi
    if [[ "$CERT_EMAIL" != *@*.* || "$CERT_EMAIL" == *$'\n'* || "$CERT_EMAIL" == *$'\r'* ]]; then
        ENVIRONMENT_ERROR="The saved Let's Encrypt account email is invalid."
        return 1
    fi
}

load_environment() {
    [[ -f "$ENV_FILE" ]] || return 1
    validate_saved_environment || die "$ENVIRONMENT_ERROR"
}

validate_existing_project_configuration() {
    local token_mode token
    EXISTING_CONFIG_INVALID=0
    EXISTING_CONFIG_ERROR=""
    EXISTING_TOKEN_INVALID=0
    EXISTING_TOKEN_ERROR=""
    if ! validate_saved_environment; then
        EXISTING_CONFIG_ERROR="$ENVIRONMENT_ERROR"
        EXISTING_CONFIG_INVALID=1
    fi
    if [[ ! -f "$TOKEN_FILE" || -L "$TOKEN_FILE" \
        || "$(stat -c %u "$TOKEN_FILE" 2>/dev/null)" != "0" ]]; then
        EXISTING_TOKEN_INVALID=1
        EXISTING_TOKEN_ERROR="The saved relay token is not a safe root-owned regular file."
    else
        token_mode="$(stat -c %a "$TOKEN_FILE" 2>/dev/null)"
        if [[ ! "$token_mode" =~ ^[0-7]{3,4}$ ]] || (( (8#$token_mode & 022) != 0 )); then
            EXISTING_TOKEN_INVALID=1
            EXISTING_TOKEN_ERROR="The saved relay token is writable by a non-root user."
        else
            token="$(tr -d '\r\n' <"$TOKEN_FILE")"
            if [[ ! "$token" =~ ^[0-9a-f]{64}$ ]]; then
                EXISTING_TOKEN_INVALID=1
                EXISTING_TOKEN_ERROR="The saved relay token is missing or invalid."
            fi
        fi
    fi
    (( EXISTING_CONFIG_INVALID == 0 ))
}

choose() {
    local header="$1"
    shift
    printf '%s\n' "$@" | "$GUM_BIN" choose --header "$header"
}

prompt_input() {
    local prompt="$1"
    local value="${2:-}"
    "$GUM_BIN" input --prompt "$prompt " --value "$value"
}

confirm() {
    "$GUM_BIN" confirm "$1"
}

spin() {
    local title="$1"
    shift
    if [[ -t 1 ]]; then
        "$GUM_BIN" spin --show-error --spinner dot --title "$title" -- "$@"
    else
        "$@"
    fi
}

install_base_dependencies() {
    local missing=()
    local command_name
    for command_name in curl tar openssl awk sed grep python3 ss; do
        command_exists "$command_name" || missing+=("$command_name")
    done
    ((${#missing[@]} == 0)) && return 0

    if command_exists apt-get; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates tar openssl gawk sed grep python3 iproute2
    elif command_exists dnf; then
        dnf install -y curl ca-certificates tar openssl gawk sed grep python3 iproute
    elif command_exists yum; then
        yum install -y curl ca-certificates tar openssl gawk sed grep python3 iproute
    else
        die "No supported package manager was found."
    fi
}

install_gum() {
    mkdir -p "${BASE_DIR}/bin"
    if have_gum; then
        return 0
    fi
    if [[ -e "$GUM_BIN" || -L "$GUM_BIN" ]]; then
        rm -f -- "$GUM_BIN" \
            || die "Could not replace the existing project Gum binary: ${GUM_BIN}"
    fi

    local machine archive_arch archive_name base_url temporary expected actual extracted
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64) archive_arch="x86_64" ;;
        aarch64|arm64) archive_arch="arm64" ;;
        *) die "Unsupported architecture for Gum: ${machine}" ;;
    esac
    archive_name="gum_${GUM_VERSION}_Linux_${archive_arch}.tar.gz"
    base_url="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}"
    temporary="$(mktemp -d /tmp/apple-relay-gum.XXXXXX)"
    trap 'rm -rf -- "$temporary"' RETURN
    curl -fsSL "${base_url}/${archive_name}" -o "${temporary}/${archive_name}"
    curl -fsSL "${base_url}/checksums.txt" -o "${temporary}/checksums.txt"
    expected="$(awk -v name="$archive_name" '$2 == name || $2 == "*" name {print $1; exit}' "${temporary}/checksums.txt")"
    actual="$(sha256_file "${temporary}/${archive_name}")"
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ && "${actual,,}" == "${expected,,}" ]] \
        || die "Gum checksum verification failed."
    tar -xzf "${temporary}/${archive_name}" -C "$temporary"
    extracted="$(find "$temporary" -type f -name gum -print -quit)"
    [[ -n "$extracted" ]] || die "The Gum archive did not contain a binary."
    install -m 0755 "$extracted" "$GUM_BIN"
    trap - RETURN
    rm -rf -- "$temporary"
}

install_envoy() {
    if [[ -x "$ENVOY_BIN" ]] \
        && "$ENVOY_BIN" --version 2>/dev/null | grep -qF "${ENVOY_VERSION}"; then
        return 0
    fi

    local machine asset_arch expected temporary actual url
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64)
            asset_arch="x86_64"
            expected="$ENVOY_SHA256_X86_64"
            ;;
        aarch64|arm64)
            asset_arch="aarch_64"
            expected="$ENVOY_SHA256_AARCH64"
            ;;
        *)
            die "Unsupported architecture for Envoy: ${machine}"
            ;;
    esac
    url="https://github.com/envoyproxy/envoy/releases/download/v${ENVOY_VERSION}/envoy-${ENVOY_VERSION}-linux-${asset_arch}"
    temporary="$(mktemp /tmp/apple-relay-envoy.XXXXXX)"
    trap 'rm -f -- "$temporary"' RETURN
    spin "Downloading Envoy ${ENVOY_VERSION}" curl -fL --retry 3 --connect-timeout 15 "$url" -o "$temporary"
    actual="$(sha256_file "$temporary")"
    [[ "${actual,,}" == "${expected,,}" ]] || die "Envoy checksum verification failed."
    install -m 0755 "$temporary" "$ENVOY_BIN"
    trap - RETURN
    rm -f -- "$temporary"
}

install_service_user() {
    mkdir -p "$STATE_DIR"
    if id -u "$SERVICE_USER" >/dev/null 2>&1; then
        return 0
    fi
    getent group "$SERVICE_USER" >/dev/null 2>&1 || groupadd --system "$SERVICE_USER"
    useradd --system --gid "$SERVICE_USER" --home-dir /nonexistent \
        --shell /usr/sbin/nologin "$SERVICE_USER"
    : >"$SERVICE_USER_MARKER"
    chmod 0600 "$SERVICE_USER_MARKER"
}

secure_runtime_files() {
    install_service_user
    chown root:root "$BASE_DIR" "${BASE_DIR}/bin" "$ENVOY_BIN"
    chmod 0755 "$BASE_DIR" "${BASE_DIR}/bin" "$ENVOY_BIN"
    chown "root:${SERVICE_USER}" "$CONFIG_DIR" "$TLS_DIR"
    chmod 0750 "$CONFIG_DIR" "$TLS_DIR"
    chown "root:${SERVICE_USER}" "$ENVOY_CONFIG" "${TLS_DIR}/fullchain.pem" "${TLS_DIR}/privkey.pem"
    chmod 0640 "$ENVOY_CONFIG" "${TLS_DIR}/privkey.pem"
    chmod 0644 "${TLS_DIR}/fullchain.pem"
    chown root:root "$ENV_FILE" "$TOKEN_FILE"
    chmod 0600 "$ENV_FILE" "$TOKEN_FILE"
}

install_certbot() {
    if ! command_exists certbot; then
        if command_exists apt-get; then
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot
        elif command_exists dnf; then
            dnf install -y certbot
        elif command_exists yum; then
            yum install -y certbot
        else
            die "Certbot is required and no supported package manager was found."
        fi
    fi

}

publish_manager() {
    mkdir -p "$BASE_DIR"
    local source_path="${BASH_SOURCE[0]:-}"
    if [[ -n "$source_path" && -f "$source_path" ]]; then
        if [[ "$(readlink -f "$source_path")" != "$(readlink -f "$BACKEND_PATH" 2>/dev/null || true)" ]]; then
            install -m 0755 "$source_path" "$BACKEND_PATH"
        else
            chmod 0755 "$BACKEND_PATH"
        fi
    else
        curl -fsSL "$SOURCE_URL" -o "${BACKEND_PATH}.tmp"
        chmod 0755 "${BACKEND_PATH}.tmp"
        mv -f "${BACKEND_PATH}.tmp" "$BACKEND_PATH"
    fi

    {
        cat <<EOF
#!/usr/bin/env bash
set -e
BACKEND="${BACKEND_PATH}"
[[ -x "\$BACKEND" ]] || { echo "apple-relay backend is missing: \$BACKEND" >&2; exit 1; }
if [[ \$# -eq 0 ]]; then
    exec "\$BACKEND" menu
fi
exec "\$BACKEND" "\$@"
EOF
    } | write_atomic "$LAUNCHER_PATH" 755
}

port_is_available() {
    local protocol="$1"
    local address="$2"
    local port="$3"
    python3 - "$protocol" "$address" "$port" <<'PY'
import socket
import sys

protocol, address, raw_port = sys.argv[1:]
family = socket.AF_INET6 if ":" in address else socket.AF_INET
kind = socket.SOCK_STREAM if protocol == "tcp" else socket.SOCK_DGRAM
sock = socket.socket(family, kind)
if protocol == "tcp":
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    sock.bind((address, int(raw_port)))
except OSError as error:
    print(
        f"{protocol.upper()} {address}:{raw_port} bind failed: {error}",
        file=sys.stderr,
    )
    raise SystemExit(1)
finally:
    sock.close()
PY
}

preflight_ports() {
    local previous_listen_port="${1:-}"
    local previous_admin_port="${2:-}"
    local service_active=0
    systemctl is-active --quiet apple-relay.service 2>/dev/null && service_active=1
    if [[ "$service_active" != "1" || "$LISTEN_PORT" != "$previous_listen_port" ]]; then
        port_is_available tcp "$LISTEN_ADDRESS" "$LISTEN_PORT" \
            || die "TCP ${LISTEN_ADDRESS}:${LISTEN_PORT} could not be bound."
    fi
    if [[ "$service_active" != "1" || "$ADMIN_PORT" != "$previous_admin_port" ]]; then
        port_is_available tcp 127.0.0.1 "$ADMIN_PORT" \
            || die "TCP 127.0.0.1:${ADMIN_PORT} could not be bound."
    fi
}

detect_public_ipv4() {
    local detected
    detected="$(curl -4fsSL --connect-timeout 5 --max-time 10 \
        https://1.1.1.1/cdn-cgi/trace 2>/dev/null \
        | awk -F= '$1 == "ip" {print $2; exit}' || true)"
    if is_valid_ipv4 "$detected"; then
        printf '%s\n' "$detected"
    fi
}

compact_file_text() {
    local path="$1"
    awk '
        NF {
            gsub(/[[:space:]]+/, " ")
            printf "%s%s", separator, $0
            separator = " "
        }
    ' "$path"
}

query_cloudflare_dns() {
    local record_type="$1"
    local max_time="${2:-$DNS_QUERY_MAX_TIME_SECONDS}"
    local connect_timeout="$DNS_QUERY_CONNECT_TIMEOUT_SECONDS"
    local response error_file error_detail curl_status parsed

    DNS_QUERY_STATE=""
    DNS_QUERY_RECORDS=""
    DNS_QUERY_ERROR=""

    if [[ "$record_type" != "A" && "$record_type" != "AAAA" ]]; then
        DNS_QUERY_ERROR="Unsupported DNS record type: ${record_type}."
        return 1
    fi
    if ! [[ "$max_time" =~ ^[1-9][0-9]*$ ]]; then
        DNS_QUERY_ERROR="Invalid DNS query timeout: ${max_time}."
        return 1
    fi
    if (( connect_timeout > max_time )); then
        connect_timeout="$max_time"
    fi

    if ! error_file="$(mktemp /tmp/apple-relay-dns-query.XXXXXX)"; then
        DNS_QUERY_ERROR="Could not create a temporary file for the Cloudflare DoH query."
        return 1
    fi
    if response="$(curl -4fsS \
        --connect-timeout "$connect_timeout" \
        --max-time "$max_time" \
        -H 'accept: application/dns-json' \
        "https://1.1.1.1/dns-query?name=${DOMAIN}&type=${record_type}" \
        2>"$error_file")"; then
        :
    else
        curl_status=$?
        error_detail="$(compact_file_text "$error_file")"
        rm -f "$error_file"
        DNS_QUERY_ERROR="Cloudflare DoH ${record_type} request failed (curl exit ${curl_status}): ${error_detail:-no error details}."
        return 1
    fi

    : >"$error_file"
    if parsed="$(python3 - "$record_type" "$response" 2>"$error_file" <<'PY'
import ipaddress
import json
import sys


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


record_type, raw = sys.argv[1:]
try:
    payload = json.loads(raw)
except (TypeError, ValueError):
    fail("Cloudflare DoH returned invalid JSON.")

if not isinstance(payload, dict):
    fail("Cloudflare DoH returned a non-object JSON response.")

status = payload.get("Status")
if type(status) is not int:
    fail("Cloudflare DoH response is missing an integer DNS Status.")
if status == 3:
    print("NXDOMAIN")
    raise SystemExit(0)
if status != 0:
    status_names = {
        1: "FORMERR",
        2: "SERVFAIL",
        4: "NOTIMP",
        5: "REFUSED",
    }
    status_name = status_names.get(status, "UNKNOWN")
    fail(f"Cloudflare DoH returned DNS Status={status} ({status_name}).")

answers = payload.get("Answer", [])
if not isinstance(answers, list):
    fail("Cloudflare DoH returned an invalid Answer field.")

wanted_type = {"A": 1, "AAAA": 28}[record_type]
wanted_version = {"A": 4, "AAAA": 6}[record_type]
records = []
for answer in answers:
    if not isinstance(answer, dict) or answer.get("type") != wanted_type:
        continue
    data = answer.get("data")
    if not isinstance(data, str):
        fail(f"Cloudflare DoH returned an invalid {record_type} record.")
    try:
        address = ipaddress.ip_address(data)
    except ValueError:
        fail(f"Cloudflare DoH returned an invalid {record_type} address: {data}.")
    if address.version != wanted_version:
        fail(f"Cloudflare DoH returned the wrong address family for {record_type}: {data}.")
    records.append(str(address))

records = sorted(set(records), key=lambda value: ipaddress.ip_address(value).packed)
print("OK" if records else "NODATA")
for record in records:
    print(record)
PY
)"; then
        :
    else
        error_detail="$(compact_file_text "$error_file")"
        rm -f "$error_file"
        DNS_QUERY_ERROR="Cloudflare DoH ${record_type} response could not be used: ${error_detail:-unknown parser error}"
        return 1
    fi
    rm -f "$error_file"

    DNS_QUERY_STATE="${parsed%%$'\n'*}"
    if [[ "$parsed" == *$'\n'* ]]; then
        DNS_QUERY_RECORDS="${parsed#*$'\n'}"
    fi
    case "$DNS_QUERY_STATE" in
        OK)
            if [[ -z "$DNS_QUERY_RECORDS" ]]; then
                DNS_QUERY_ERROR="Cloudflare DoH ${record_type} response reported records but contained none."
                return 1
            fi
            ;;
        NODATA|NXDOMAIN)
            if [[ -n "$DNS_QUERY_RECORDS" ]]; then
                DNS_QUERY_ERROR="Cloudflare DoH ${record_type} response contained inconsistent data."
                return 1
            fi
            ;;
        *)
            DNS_QUERY_ERROR="Cloudflare DoH ${record_type} response returned an unknown parser state."
            return 1
            ;;
    esac
}

dns_now_epoch() {
    date +%s
}

dns_timeout_before_deadline() {
    local deadline="${1:-}"
    local now remaining timeout="$DNS_QUERY_MAX_TIME_SECONDS"
    if [[ -n "$deadline" ]]; then
        now="$(dns_now_epoch)"
        remaining=$((deadline - now))
        (( remaining > 0 )) || return 1
        if (( timeout > remaining )); then
            timeout="$remaining"
        fi
    fi
    printf '%s\n' "$timeout"
}

format_dns_record_state() {
    local state="$1"
    local records="$2"
    case "$state" in
        OK) printf '%s' "${records//$'\n'/,}" ;;
        NODATA) printf 'none' ;;
        NXDOMAIN) printf 'NXDOMAIN' ;;
        *) printf 'unknown' ;;
    esac
}

dns_points_to_relay() {
    local deadline="${1:-}"
    local query_timeout

    DNS_A_STATE=""
    DNS_A_RECORDS=""
    DNS_AAAA_STATE=""
    DNS_AAAA_RECORDS=""
    DNS_LAST_DETAIL=""
    DNS_LAST_ERROR=""

    if ! query_timeout="$(dns_timeout_before_deadline "$deadline")"; then
        DNS_LAST_ERROR="The DNS validation deadline expired before the A query completed."
        return 3
    fi
    if ! query_cloudflare_dns A "$query_timeout"; then
        DNS_LAST_ERROR="$DNS_QUERY_ERROR"
        return 2
    fi
    DNS_A_STATE="$DNS_QUERY_STATE"
    DNS_A_RECORDS="$DNS_QUERY_RECORDS"

    if ! query_timeout="$(dns_timeout_before_deadline "$deadline")"; then
        DNS_LAST_ERROR="The DNS validation deadline expired before the AAAA query completed."
        return 3
    fi
    if ! query_cloudflare_dns AAAA "$query_timeout"; then
        DNS_LAST_ERROR="$DNS_QUERY_ERROR"
        return 2
    fi
    DNS_AAAA_STATE="$DNS_QUERY_STATE"
    DNS_AAAA_RECORDS="$DNS_QUERY_RECORDS"
    DNS_LAST_DETAIL="A=$(format_dns_record_state "$DNS_A_STATE" "$DNS_A_RECORDS"), AAAA=$(format_dns_record_state "$DNS_AAAA_STATE" "$DNS_AAAA_RECORDS")"

    [[ "$DNS_A_STATE" == "OK" \
        && "$DNS_A_RECORDS" == "$PUBLIC_IPV4" \
        && "$DNS_AAAA_STATE" == "NODATA" ]]
}

show_dns_instructions() {
    {
        printf 'Configure this DNS record before continuing:\n\n'
        printf 'Type:   A\n'
        printf 'Name:   %s\n' "$DOMAIN"
        printf 'Value:  %s\n' "$PUBLIC_IPV4"
        printf 'Proxy:  DNS only / disabled\n\n'
        printf 'Remove any AAAA record for this hostname.\n'
        printf 'The installer will verify the public answer through 1.1.1.1 DNS-over-HTTPS.\n'
    } | "$GUM_BIN" style --border rounded --padding "1 2" --border-foreground 212
}

wait_for_dns() {
    local start_time deadline now remaining sleep_seconds status
    local attempt=0
    local consecutive_errors=0
    local last_valid_detail="no complete DNS response"
    local last_query_error=""
    show_dns_instructions
    confirm "The DNS record is configured. Start the 1.1.1.1 propagation check?" \
        || die "DNS validation was cancelled."

    start_time="$(dns_now_epoch)"
    deadline=$((start_time + DNS_PROPAGATION_TIMEOUT_SECONDS))
    log_info "Checking DNS through 1.1.1.1 for up to ${DNS_PROPAGATION_TIMEOUT_SECONDS}s. Query errors will be reported immediately."
    while true; do
        now="$(dns_now_epoch)"
        (( now < deadline )) || break
        (( attempt += 1 ))

        if dns_points_to_relay "$deadline"; then
            log_ok "1.1.1.1 resolves ${DOMAIN} to ${PUBLIC_IPV4} with no AAAA record."
            return 0
        else
            status=$?
        fi

        now="$(dns_now_epoch)"
        remaining=$((deadline - now))
        if (( remaining < 0 )); then
            remaining=0
        fi

        if (( status == 2 )); then
            (( consecutive_errors += 1 ))
            last_query_error="$DNS_LAST_ERROR"
            log_warn "DNS check ${attempt} could not query 1.1.1.1: ${DNS_LAST_ERROR} Retrying (${remaining}s remaining)."
            if (( consecutive_errors >= DNS_MAX_CONSECUTIVE_ERRORS )); then
                die "DNS validation stopped after ${consecutive_errors} consecutive Cloudflare DoH errors. Last error: ${DNS_LAST_ERROR}"
            fi
        elif (( status == 3 )); then
            break
        else
            consecutive_errors=0
            last_valid_detail="$DNS_LAST_DETAIL"
            log_info "Waiting for DNS propagation via 1.1.1.1 (attempt ${attempt}, ${remaining}s remaining; ${DNS_LAST_DETAIL})."
        fi

        (( remaining > 0 )) || break
        sleep_seconds="$DNS_POLL_INTERVAL_SECONDS"
        if (( sleep_seconds > remaining )); then
            sleep_seconds="$remaining"
        fi
        sleep "$sleep_seconds"
    done

    if [[ "$last_valid_detail" != "no complete DNS response" ]]; then
        die "DNS validation timed out after ${DNS_PROPAGATION_TIMEOUT_SECONDS}s. Expected only A=${PUBLIC_IPV4} for ${DOMAIN} with no AAAA record; last answer was ${last_valid_detail}."
    fi
    die "DNS validation timed out after ${DNS_PROPAGATION_TIMEOUT_SECONDS}s without a complete DNS response. Last query error: ${last_query_error:-deadline expired}."
}

require_dns_points_to_relay() {
    local action="$1"
    local status
    if dns_points_to_relay; then
        return 0
    else
        status=$?
    fi
    if (( status == 2 )); then
        die "${action} was not attempted because the Cloudflare DoH check failed: ${DNS_LAST_ERROR}"
    fi
    die "${action} was not attempted. Expected only A=${PUBLIC_IPV4} for ${DOMAIN} with no AAAA record; received ${DNS_LAST_DETAIL:-no complete DNS response}."
}

certificate_matches_key() {
    local certificate="$1"
    local private_key="$2"
    local cert_hash key_hash
    cert_hash="$(openssl x509 -in "$certificate" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    key_hash="$(openssl pkey -in "$private_key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    [[ -n "$cert_hash" && "$cert_hash" == "$key_hash" ]]
}

certificate_is_current_for_domain() {
    local certificate="$1"
    local verification_time="${2:-}"
    local not_before not_after not_before_epoch not_after_epoch current_time
    [[ -s "$certificate" ]] || return 1
    [[ -z "$verification_time" || "$verification_time" =~ ^[0-9]+$ ]] || return 1

    not_before="$(LC_ALL=C openssl x509 -in "$certificate" -noout -startdate 2>/dev/null)" \
        || return 1
    not_after="$(LC_ALL=C openssl x509 -in "$certificate" -noout -enddate 2>/dev/null)" \
        || return 1
    not_before_epoch="$(LC_ALL=C date -u -d "${not_before#notBefore=}" +%s 2>/dev/null)" \
        || return 1
    not_after_epoch="$(LC_ALL=C date -u -d "${not_after#notAfter=}" +%s 2>/dev/null)" \
        || return 1
    current_time="${verification_time:-$(date -u +%s)}"
    (( current_time >= not_before_epoch && current_time <= not_after_epoch )) \
        || return 1
    openssl x509 -in "$certificate" -noout -checkhost "$DOMAIN" >/dev/null 2>&1
}

validate_certificate_pair() {
    local certificate="$1"
    local private_key="$2"
    [[ -s "$certificate" && -s "$private_key" ]] || return 1
    certificate_is_current_for_domain "$certificate" \
        || return 1
    certificate_matches_key "$certificate" "$private_key" \
        || return 1
}

validate_certificate() {
    local certificate="${TLS_DIR}/fullchain.pem"
    local private_key="${TLS_DIR}/privkey.pem"
    validate_certificate_pair "$certificate" "$private_key" \
        || die "The TLS certificate is invalid, expired, mismatched, or does not cover ${DOMAIN}."
    chmod 0644 "$certificate"
    chmod 0600 "$private_key"
}

copy_certificate() {
    local certificate="$1"
    local private_key="$2"
    [[ "$certificate" = /* && "$private_key" = /* ]] || die "Certificate paths must be absolute."
    [[ -f "$certificate" && -f "$private_key" ]] || die "A certificate source file does not exist."
    mkdir -p "$TLS_DIR"
    install -m 0644 "$certificate" "${TLS_DIR}/fullchain.pem.tmp"
    install -m 0600 "$private_key" "${TLS_DIR}/privkey.pem.tmp"
    if ! validate_certificate_pair "${TLS_DIR}/fullchain.pem.tmp" "${TLS_DIR}/privkey.pem.tmp"; then
        rm -f "${TLS_DIR}/fullchain.pem.tmp" "${TLS_DIR}/privkey.pem.tmp"
        die "The replacement certificate failed validation; the deployed certificate was not changed."
    fi
    mv -f "${TLS_DIR}/fullchain.pem.tmp" "${TLS_DIR}/fullchain.pem"
    mv -f "${TLS_DIR}/privkey.pem.tmp" "${TLS_DIR}/privkey.pem"
    validate_certificate
    if id -u "$SERVICE_USER" >/dev/null 2>&1; then
        chown "root:${SERVICE_USER}" "${TLS_DIR}/fullchain.pem" "${TLS_DIR}/privkey.pem"
        chmod 0644 "${TLS_DIR}/fullchain.pem"
        chmod 0640 "${TLS_DIR}/privkey.pem"
    fi
}

copy_letsencrypt_lineage() {
    local lineage="${LETSENCRYPT_LIVE_DIR}/${DOMAIN}"
    [[ -s "${lineage}/fullchain.pem" && -s "${lineage}/privkey.pem" ]] \
        || die "The Let's Encrypt lineage for ${DOMAIN} is missing."
    copy_certificate "${lineage}/fullchain.pem" "${lineage}/privkey.pem"
}

ensure_letsencrypt_certificate() {
    local deployed_certificate="${TLS_DIR}/fullchain.pem"
    local deployed_private_key="${TLS_DIR}/privkey.pem"
    local lineage="${LETSENCRYPT_LIVE_DIR}/${DOMAIN}"

    if validate_certificate_pair "${lineage}/fullchain.pem" "${lineage}/privkey.pem"; then
        install_certbot
        if ! validate_certificate_pair "$deployed_certificate" "$deployed_private_key" \
            || [[ "$(sha256_file "$deployed_certificate")" \
                    != "$(sha256_file "${lineage}/fullchain.pem")" ]] \
            || [[ "$(sha256_file "$deployed_private_key")" \
                    != "$(sha256_file "${lineage}/privkey.pem")" ]]; then
            copy_letsencrypt_lineage
        fi
        log_info "The existing Let's Encrypt certificate is valid and within its validity period; it will be reused."
        return 0
    fi

    if validate_certificate_pair "$deployed_certificate" "$deployed_private_key"; then
        log_warn "The deployed certificate is valid, but no renewable Certbot lineage is available; requesting a managed Let's Encrypt certificate."
        issue_letsencrypt_certificate
        return 0
    fi

    log_info "No valid current certificate was found; requesting a Let's Encrypt certificate."
    issue_letsencrypt_certificate
}

issue_letsencrypt_certificate() {
    local force="${1:-0}"
    install_certbot
    port_is_available tcp "$LISTEN_ADDRESS" 80 \
        || die "TCP ${LISTEN_ADDRESS}:80 could not be bound for the HTTP-01 challenge."
    local address_args=()
    local renewal_args=(--keep-until-expiring)
    [[ "$LISTEN_ADDRESS" == "0.0.0.0" ]] || address_args=(--http-01-address "$LISTEN_ADDRESS")
    [[ "$force" == "1" ]] && renewal_args=(--force-renewal)
    certbot certonly --non-interactive --agree-tos --email "$CERT_EMAIL" \
        --cert-name "$DOMAIN" "${renewal_args[@]}" -d "$DOMAIN" \
        --standalone --preferred-challenges http "${address_args[@]}"
    copy_letsencrypt_lineage
}

render_envoy_config() {
    local destination="${1:-$ENVOY_CONFIG}"
    local token
    token="$(tr -d '\r\n' <"$TOKEN_FILE")"
    [[ "$token" =~ ^[0-9a-f]{64}$ ]] || die "The relay token is missing or invalid."

    {
        cat <<EOF
admin:
  address:
    socket_address:
      address: 127.0.0.1
      port_value: ${ADMIN_PORT}

static_resources:
  listeners:
  - name: relay_http2
    address:
      socket_address:
        protocol: TCP
        address: ${LISTEN_ADDRESS}
        port_value: ${LISTEN_PORT}
    filter_chains:
    - transport_socket:
        name: envoy.transport_sockets.tls
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
          common_tls_context:
            alpn_protocols: [h2]
            tls_certificates:
            - certificate_chain:
                filename: /etc/apple-relay/tls/fullchain.pem
              private_key:
                filename: /etc/apple-relay/tls/privkey.pem
      filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          codec_type: HTTP2
          stat_prefix: relay_http2
          stream_idle_timeout: 300s
          request_timeout: 0s
          route_config:
            name: relay_routes_http2
            virtual_hosts:
            - name: relay
              domains: ["*"]
              routes:
              - match:
                  connect_matcher: {}
                route:
                  cluster: dynamic_forward_proxy
                  timeout: 0s
                  upgrade_configs:
                  - upgrade_type: CONNECT
                    connect_config: {}
                  - upgrade_type: CONNECT-UDP
                    connect_config: {}
          http_filters:
          - name: envoy.filters.http.rbac
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.rbac.v3.RBAC
              rules:
                action: ALLOW
                policies:
                  relay_token:
                    permissions:
                    - header:
                        name: x-relay-token
                        string_match:
                          exact: "${token}"
                    principals:
                    - any: true
          - name: envoy.filters.http.dynamic_forward_proxy
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.dynamic_forward_proxy.v3.FilterConfig
              dns_cache_config:
                name: relay_dns_cache
                dns_lookup_family: V4_PREFERRED
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
          http2_protocol_options:
            allow_connect: true

  clusters:
  - name: dynamic_forward_proxy
    connect_timeout: 10s
    lb_policy: CLUSTER_PROVIDED
    cluster_type:
      name: envoy.clusters.dynamic_forward_proxy
      typed_config:
        "@type": type.googleapis.com/envoy.extensions.clusters.dynamic_forward_proxy.v3.ClusterConfig
        dns_cache_config:
          name: relay_dns_cache
          dns_lookup_family: V4_PREFERRED
EOF
    } | write_atomic "$destination" 600
    if id -u "$SERVICE_USER" >/dev/null 2>&1; then
        chown "root:${SERVICE_USER}" "$destination"
        chmod 0640 "$destination"
    fi
}

validate_envoy_config() {
    [[ -x "$ENVOY_BIN" ]] || die "The Envoy binary is missing."
    local validation_log
    validation_log="$(mktemp /tmp/apple-relay-envoy-validate.XXXXXX)"
    if ! "$ENVOY_BIN" --mode validate --disable-hot-restart \
        -c "$ENVOY_CONFIG" >"$validation_log" 2>&1; then
        cat "$validation_log" >&2
        rm -f "$validation_log"
        return 1
    fi
    rm -f "$validation_log"
}

existing_envoy_config_matches_inputs() {
    local temporary expected_config match_status=1
    temporary="$(mktemp -d /tmp/apple-relay-envoy-compare.XXXXXX)" || return 1
    expected_config="${temporary}/envoy.yaml"
    if render_envoy_config "$expected_config" \
        && [[ "$(sha256_file "$expected_config")" == "$(sha256_file "$ENVOY_CONFIG")" ]]; then
        match_status=0
    fi
    rm -rf -- "$temporary"
    return "$match_status"
}

assess_existing_configuration() {
    local validation_log
    REUSE_EXISTING_CONFIG=0
    REBUILD_EXISTING_ENVOY_CONFIG=0

    if ! validate_existing_project_configuration; then
        if (( EXISTING_TOKEN_INVALID == 1 )); then
            log_warn "${EXISTING_TOKEN_ERROR} A new token will be generated."
        fi
        return 1
    fi
    if [[ "$LISTEN_ADDRESS" != "0.0.0.0" || "$LISTEN_PORT" != "443" ]]; then
        EXISTING_CONFIG_INVALID=1
        EXISTING_CONFIG_ERROR="The saved listener ${LISTEN_ADDRESS}:${LISTEN_PORT} is incompatible with the required 0.0.0.0:443 listener."
        return 1
    fi
    REUSE_EXISTING_CONFIG=1

    if (( EXISTING_TOKEN_INVALID == 1 )); then
        log_warn "${EXISTING_TOKEN_ERROR} A new token will be generated; existing client profiles will need to be updated."
        REBUILD_EXISTING_ENVOY_CONFIG=1
    fi
    if ! validate_certificate_pair "${TLS_DIR}/fullchain.pem" "${TLS_DIR}/privkey.pem"; then
        log_warn "The deployed TLS certificate is missing or invalid and will be repaired without discarding the other configuration."
    fi

    if [[ -e "$ENVOY_CONFIG" || -L "$ENVOY_CONFIG" ]] \
        && ! safe_root_owned_file "$ENVOY_CONFIG"; then
        die "Refusing an unsafe generated Envoy configuration path: ${ENVOY_CONFIG}"
    fi
    if (( EXISTING_TOKEN_INVALID == 0 )) && [[ -f "$ENVOY_CONFIG" ]] \
        && ! existing_envoy_config_matches_inputs; then
        REBUILD_EXISTING_ENVOY_CONFIG=1
        log_warn "The generated Envoy configuration does not match the saved token or network settings and will be rebuilt."
        return 0
    fi
    if [[ ! -f "$ENVOY_CONFIG" ]] \
        || ! safe_root_owned_file "$ENVOY_BIN" || [[ ! -x "$ENVOY_BIN" ]]; then
        REBUILD_EXISTING_ENVOY_CONFIG=1
        log_warn "The generated Envoy configuration cannot be validated and will be rebuilt."
        return 0
    fi
    if ! validation_log="$(mktemp /tmp/apple-relay-existing-envoy-validate.XXXXXX)"; then
        REBUILD_EXISTING_ENVOY_CONFIG=1
        log_warn "A temporary validation file could not be created; the generated Envoy configuration will be rebuilt."
        return 0
    fi
    if ! "$ENVOY_BIN" --mode validate --disable-hot-restart \
        -c "$ENVOY_CONFIG" >"$validation_log" 2>&1; then
        log_warn "The generated Envoy configuration failed validation and will be rebuilt: $(compact_file_text "$validation_log")"
        REBUILD_EXISTING_ENVOY_CONFIG=1
    fi
    rm -f "$validation_log"
}

wait_for_relay_ready() {
    local start_time deadline now response error_file error_detail curl_status active_state sub_state
    local consecutive_ready_checks=0
    RELAY_READY_ERROR=""
    if ! error_file="$(mktemp /tmp/apple-relay-ready.XXXXXX)"; then
        RELAY_READY_ERROR="Could not create a temporary file for the readiness check."
        return 1
    fi
    start_time="$(date +%s)"
    deadline=$((start_time + RELAY_READY_TIMEOUT_SECONDS))

    while true; do
        : >"$error_file"
        if response="$(curl -sS --connect-timeout 1 --max-time 1 \
            "http://127.0.0.1:${ADMIN_PORT}/ready" 2>"$error_file")"; then
            if [[ "$response" == "LIVE" ]]; then
                active_state="$(systemctl show apple-relay.service --property=ActiveState --value 2>/dev/null || true)"
                sub_state="$(systemctl show apple-relay.service --property=SubState --value 2>/dev/null || true)"
                if [[ "$active_state" == "active" && "$sub_state" == "running" ]]; then
                    (( consecutive_ready_checks += 1 ))
                    if (( consecutive_ready_checks >= 2 )); then
                        rm -f "$error_file"
                        RELAY_READY_ERROR=""
                        return 0
                    fi
                    RELAY_READY_ERROR="Envoy reported LIVE once; waiting for a stable second check."
                else
                    consecutive_ready_checks=0
                    RELAY_READY_ERROR="Envoy reported LIVE, but systemd state is '${active_state:-unknown}/${sub_state:-unknown}'."
                fi
            else
                consecutive_ready_checks=0
                response="${response//$'\r'/ }"
                response="${response//$'\n'/ }"
                RELAY_READY_ERROR="The Envoy readiness endpoint returned '${response:0:200}'."
            fi
        else
            consecutive_ready_checks=0
            curl_status=$?
            error_detail="$(compact_file_text "$error_file")"
            RELAY_READY_ERROR="The Envoy readiness endpoint could not be reached (curl exit ${curl_status}): ${error_detail:-no error details}."
        fi

        if systemctl is-failed --quiet apple-relay.service 2>/dev/null; then
            RELAY_READY_ERROR="The systemd service entered the failed state. ${RELAY_READY_ERROR}"
            rm -f "$error_file"
            return 1
        fi
        sub_state="$(systemctl show apple-relay.service --property=SubState --value 2>/dev/null || true)"
        if [[ "$sub_state" == "auto-restart" || "$sub_state" == "failed" ]]; then
            RELAY_READY_ERROR="The systemd service entered '${sub_state}'. ${RELAY_READY_ERROR}"
            rm -f "$error_file"
            return 1
        fi

        now="$(date +%s)"
        if (( now >= deadline )); then
            RELAY_READY_ERROR="Envoy did not report LIVE within ${RELAY_READY_TIMEOUT_SECONDS}s. ${RELAY_READY_ERROR}"
            rm -f "$error_file"
            return 1
        fi
        sleep 0.2
    done
}

relay_journal_cursor() {
    journalctl -n 1 --show-cursor --no-pager 2>/dev/null \
        | sed -n 's/^-- cursor: //p' \
        | tail -n 1
}

show_relay_journal_since() {
    local cursor="$1"
    local since="$2"
    if [[ -n "$cursor" ]]; then
        if journalctl -u apple-relay.service --after-cursor="$cursor" --no-pager >&2; then
            return 0
        fi
        log_warn "Could not read the service journal by cursor; falling back to a timestamp."
    fi
    if ! journalctl -u apple-relay.service --since="$since" --no-pager >&2; then
        log_warn "Could not read the Apple Relay service journal."
    fi
}

restart_relay_service() {
    local cursor since restart_status failure_reason active_state sub_state
    local restart_succeeded=0
    cursor="$(relay_journal_cursor || true)"
    since="$(date --iso-8601=seconds)"
    systemctl reset-failed apple-relay.service >/dev/null 2>&1 || true

    if systemctl restart apple-relay.service; then
        restart_succeeded=1
        if wait_for_relay_ready; then
            return 0
        fi
        failure_reason="Apple Relay did not become ready. ${RELAY_READY_ERROR}"
    else
        restart_status=$?
        failure_reason="systemctl could not restart Apple Relay (exit ${restart_status})."
    fi

    log_error "$failure_reason"
    active_state="$(systemctl show apple-relay.service --property=ActiveState --value 2>/dev/null || true)"
    sub_state="$(systemctl show apple-relay.service --property=SubState --value 2>/dev/null || true)"
    if (( restart_succeeded == 1 )) \
        || [[ "$active_state" == "failed" || "$sub_state" == "auto-restart" ]]; then
        if ! systemctl stop apple-relay.service; then
            log_warn "Apple Relay could not be stopped after the failed start."
        fi
    fi
    show_relay_journal_since "$cursor" "$since"
    return 1
}

install_systemd_units() {
    {
        cat <<EOF
[Unit]
Description=Apple Network Relay (Envoy MASQUE)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60s
StartLimitBurst=5

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=${ENVOY_BIN} -c ${ENVOY_CONFIG} --log-level info --disable-hot-restart
Restart=on-failure
RestartSec=3s
TimeoutStartSec=120s
TimeoutStopSec=30s
LimitNOFILE=1048576
UMask=0027

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
PrivateDevices=yes
PrivateTmp=yes
ProtectControlGroups=yes
ProtectHome=yes
ProtectKernelLogs=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectSystem=strict
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF
    } | write_atomic "$SERVICE_UNIT" 644

    {
        cat <<EOF
[Unit]
Description=Renew the Apple Relay TLS certificate

[Service]
Type=oneshot
ExecStart=${LAUNCHER_PATH} renew-cert --quiet
EOF
    } | write_atomic "$RENEW_SERVICE_UNIT" 644

    {
        cat <<'EOF'
[Unit]
Description=Daily Apple Relay TLS certificate renewal check

[Timer]
OnCalendar=daily
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    } | write_atomic "$RENEW_TIMER_UNIT" 644

    systemctl daemon-reload
    assert_no_project_unit_dropins \
        || die "The Apple Relay units have unrecognized systemd drop-ins."
    systemctl enable apple-relay.service >/dev/null
}

systemd_unit_property() {
    local unit_name="$1"
    local property_name="$2"
    local output
    if output="$(systemctl show "$unit_name" --property="$property_name" --value 2>&1)"; then
        printf '%s\n' "$output"
        return 0
    fi
    output="${output//$'\r'/ }"
    output="${output//$'\n'/ }"
    log_error "Could not query systemd property ${property_name} for ${unit_name}: ${output:-no error details}"
    return 1
}

systemd_effective_active_state() {
    local unit_name="$1"
    local load_state active_state
    load_state="$(systemd_unit_property "$unit_name" LoadState)" || return 1
    if [[ "$load_state" == "not-found" ]]; then
        printf 'inactive\n'
        return 0
    fi
    active_state="$(systemd_unit_property "$unit_name" ActiveState)" || return 1
    if [[ -z "$active_state" ]]; then
        log_error "systemd returned an empty ActiveState for ${unit_name}."
        return 1
    fi
    printf '%s\n' "$active_state"
}

assert_no_project_unit_dropins() {
    local unit_name dropin_paths
    for unit_name in apple-relay.service apple-relay-renew.service apple-relay-renew.timer; do
        dropin_paths="$(systemd_unit_property "$unit_name" DropInPaths)" \
            || return 1
        if [[ -n "$dropin_paths" ]]; then
            log_error "Refusing ${unit_name} because systemd applies unrecognized drop-ins: ${dropin_paths}"
            return 1
        fi
    done
}

safe_root_owned_file() {
    local path="$1"
    local mode
    [[ -f "$path" && ! -L "$path" \
        && "$(stat -c %u "$path" 2>/dev/null)" == "0" ]] || return 1
    mode="$(stat -c %a "$path" 2>/dev/null)"
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 022) == 0 ))
}

safe_root_owned_directory() {
    local path="$1"
    local mode
    [[ -d "$path" && ! -L "$path" \
        && "$(stat -c %u "$path" 2>/dev/null)" == "0" ]] || return 1
    mode="$(stat -c %a "$path" 2>/dev/null)"
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 022) == 0 ))
}

assert_existing_tls_layout_safe() {
    local path
    if [[ -e "$TLS_DIR" || -L "$TLS_DIR" ]]; then
        safe_root_owned_directory "$TLS_DIR" \
            || die "Refusing an unsafe TLS configuration directory: ${TLS_DIR}"
    fi
    for path in "${TLS_DIR}/fullchain.pem" "${TLS_DIR}/privkey.pem"; do
        if [[ -e "$path" || -L "$path" ]]; then
            safe_root_owned_file "$path" \
                || die "Refusing an unsafe TLS configuration file: ${path}"
        fi
    done
}

project_unit_is_owned() {
    local path="$1"
    safe_root_owned_file "$path" || return 1
    case "$path" in
        "$SERVICE_UNIT")
            grep -Fqx 'Description=Apple Network Relay (Envoy MASQUE)' "$path" \
                && grep -Fqx "User=${SERVICE_USER}" "$path" \
                && grep -Fqx "Group=${SERVICE_USER}" "$path" \
                && { grep -Fqx "ExecStart=${ENVOY_BIN} -c ${ENVOY_CONFIG} --log-level info" "$path" \
                    || grep -Fqx "ExecStart=${ENVOY_BIN} -c ${ENVOY_CONFIG} --log-level info --disable-hot-restart" "$path"; }
            ;;
        "$RENEW_SERVICE_UNIT")
            grep -Fqx 'Description=Renew the Apple Relay TLS certificate' "$path" \
                && grep -Fqx "ExecStart=${LAUNCHER_PATH} renew-cert --quiet" "$path"
            ;;
        "$RENEW_TIMER_UNIT")
            grep -Fqx 'Description=Daily Apple Relay TLS certificate renewal check' "$path" \
                && grep -Fqx 'OnCalendar=daily' "$path" \
                && grep -Fqx 'Persistent=true' "$path"
            ;;
        *)
            return 1
            ;;
    esac
}

launcher_is_owned() {
    safe_root_owned_file "$LAUNCHER_PATH" || return 1
    grep -Fqx "BACKEND=\"${BACKEND_PATH}\"" "$LAUNCHER_PATH"
}

detect_previous_installation() {
    PREVIOUS_INSTALLATION_DETECTED=0
    local unit_path dropin_dir fragment_path dropin_paths load_state index
    local unit_names=(apple-relay.service apple-relay-renew.service apple-relay-renew.timer)
    local unit_paths=("$SERVICE_UNIT" "$RENEW_SERVICE_UNIT" "$RENEW_TIMER_UNIT")
    for index in "${!unit_names[@]}"; do
        load_state="$(systemd_unit_property "${unit_names[$index]}" LoadState)" \
            || die "Could not inspect ${unit_names[$index]}."
        [[ -n "$load_state" ]] \
            || die "systemd returned an empty LoadState for ${unit_names[$index]}."
        if [[ "$load_state" != "not-found" ]]; then
            fragment_path="$(systemd_unit_property "${unit_names[$index]}" FragmentPath)" \
                || die "Could not inspect ${unit_names[$index]}."
            dropin_paths="$(systemd_unit_property "${unit_names[$index]}" DropInPaths)" \
                || die "Could not inspect ${unit_names[$index]}."
            if [[ -n "$dropin_paths" ]]; then
                die "Refusing to replace ${unit_names[$index]} with active systemd drop-ins: ${dropin_paths}"
            fi
            [[ -n "$fragment_path" ]] \
                || die "Refusing a loaded ${unit_names[$index]} without a persistent unit file."
            if [[ "$(readlink -f "$fragment_path" 2>/dev/null || printf '%s' "$fragment_path")" \
                    != "$(readlink -f "${unit_paths[$index]}" 2>/dev/null || printf '%s' "${unit_paths[$index]}")" ]]; then
                die "Refusing to manage ${unit_names[$index]} from an unexpected path: ${fragment_path}"
            fi
        fi
    done
    for dropin_dir in "${SERVICE_UNIT}.d" "${RENEW_SERVICE_UNIT}.d" "${RENEW_TIMER_UNIT}.d"; do
        if [[ -e "$dropin_dir" || -L "$dropin_dir" ]]; then
            [[ -d "$dropin_dir" && ! -L "$dropin_dir" ]] \
                || die "Refusing an unsafe systemd drop-in path: ${dropin_dir}"
            if find "$dropin_dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
                die "Refusing to replace a unit with unrecognized systemd drop-ins: ${dropin_dir}"
            fi
        fi
    done
    for unit_path in "$SERVICE_UNIT" "$RENEW_SERVICE_UNIT" "$RENEW_TIMER_UNIT"; do
        if [[ -e "$unit_path" || -L "$unit_path" ]]; then
            project_unit_is_owned "$unit_path" \
                || die "Refusing to replace an unrecognized systemd unit: ${unit_path}"
            PREVIOUS_INSTALLATION_DETECTED=1
        fi
    done
    if [[ -e "$LAUNCHER_PATH" || -L "$LAUNCHER_PATH" ]]; then
        launcher_is_owned \
            || die "Refusing to replace an unrecognized command: ${LAUNCHER_PATH}"
        PREVIOUS_INSTALLATION_DETECTED=1
    fi
    if [[ -e "$BASE_DIR" ]]; then
        is_managed_dir "$BASE_DIR" \
            || die "Refusing to replace an unowned runtime directory: ${BASE_DIR}"
        if find "$BASE_DIR" -mindepth 1 -maxdepth 1 ! -name "$OWNERSHIP_MARKER" -print -quit \
            | grep -q .; then
            PREVIOUS_INSTALLATION_DETECTED=1
        fi
    fi
}

disable_previous_unit() {
    local unit_name="$1"
    local previous_state="$2"
    case "$previous_state" in
        not-found) return 0 ;;
        enabled-runtime) systemctl disable --runtime "$unit_name" ;;
        enabled|disabled) systemctl disable "$unit_name" ;;
        *)
            log_error "Cannot disable ${unit_name} from unsupported state '${previous_state:-empty}'."
            return 1
            ;;
    esac
}

remove_previous_runtime_installation() {
    (( PREVIOUS_INSTALLATION_DETECTED == 1 )) || return 0
    local service_state renew_state timer_state
    log_info "Removing the previous Apple Relay runtime. Configuration will be preserved unless validation failed."

    if ! disable_previous_unit apple-relay.service "$INSTALL_SERVICE_ENABLE_STATE"; then
        log_error "The previous Apple Relay service could not be disabled."
        return 1
    fi
    if ! disable_previous_unit apple-relay-renew.timer "$INSTALL_TIMER_ENABLE_STATE"; then
        log_error "The previous Apple Relay timer could not be disabled."
        return 1
    fi
    if ! systemctl stop apple-relay-renew.timer apple-relay-renew.service apple-relay.service; then
        log_warn "systemctl reported an error while stopping the previous runtime; verifying the final state."
    fi
    service_state="$(systemd_effective_active_state apple-relay.service)" || return 1
    renew_state="$(systemd_effective_active_state apple-relay-renew.service)" || return 1
    timer_state="$(systemd_effective_active_state apple-relay-renew.timer)" || return 1
    if [[ "$service_state" != "inactive" && "$service_state" != "failed" ]] \
        || [[ "$renew_state" != "inactive" && "$renew_state" != "failed" ]] \
        || [[ "$timer_state" != "inactive" && "$timer_state" != "failed" ]]; then
        log_error "The previous Apple Relay services could not be stopped safely."
        return 1
    fi

    if ! rm -f -- "$SERVICE_UNIT" "$RENEW_SERVICE_UNIT" "$RENEW_TIMER_UNIT"; then
        log_error "The previous systemd unit files could not be removed."
        return 1
    fi
    if [[ -e "$LAUNCHER_PATH" || -L "$LAUNCHER_PATH" ]]; then
        launcher_is_owned || {
            log_error "The relayctl launcher changed after validation; refusing to remove it."
            return 1
        }
        if ! rm -f -- "$LAUNCHER_PATH"; then
            log_error "The previous relayctl launcher could not be removed."
            return 1
        fi
    fi
    if [[ -e "$BASE_DIR" ]]; then
        is_managed_dir "$BASE_DIR" || {
            log_error "The runtime directory changed after validation; refusing to remove it."
            return 1
        }
        if ! remove_managed_dir "$BASE_DIR"; then
            log_error "The previous runtime directory could not be removed."
            return 1
        fi
    fi
    if ! systemctl daemon-reload; then
        log_error "systemd could not reload after removing the previous runtime."
        return 1
    fi
    log_ok "The previous runtime was removed safely."
}

prepare_runtime_installation() {
    remove_previous_runtime_installation || return 1
    if (( EXISTING_CONFIG_INVALID == 1 )); then
        log_warn "Replacing only relay.env because environment validation failed: ${EXISTING_CONFIG_ERROR}"
        if ! rm -f -- "$ENV_FILE"; then
            log_error "The invalid relay.env file could not be removed."
            return 1
        fi
    fi
    if (( EXISTING_TOKEN_INVALID == 1 )); then
        if ! rm -f -- "$TOKEN_FILE"; then
            log_error "The invalid relay token could not be removed."
            return 1
        fi
    fi
    claim_project_dirs
    install_gum
    publish_manager
    install_envoy
    if (( PREVIOUS_INSTALLATION_DETECTED == 1 )); then
        preflight_ports "" ""
    fi
}

backup_install_path() {
    local source="$1"
    local destination="$2"
    if [[ -e "$source" || -L "$source" ]]; then
        cp -a -- "$source" "$destination"
    fi
}

cleanup_install_backup() {
    if [[ -z "$INSTALL_BACKUP_DIR" ]]; then
        return 0
    fi
    if [[ "$INSTALL_BACKUP_DIR" != /tmp/apple-relay-install-backup.* \
        || ! -d "$INSTALL_BACKUP_DIR" || -L "$INSTALL_BACKUP_DIR" ]]; then
        log_warn "Refusing to remove an unexpected installation backup path: ${INSTALL_BACKUP_DIR}"
        return 1
    fi
    if ! rm -rf -- "$INSTALL_BACKUP_DIR"; then
        log_error "Could not remove the installation backup: ${INSTALL_BACKUP_DIR}"
        return 1
    fi
    INSTALL_BACKUP_DIR=""
}

resume_preinstall_renewal_state() {
    local resume_failed=0
    if (( INSTALL_RENEW_SERVICE_WAS_ACTIVE == 1 )); then
        systemctl start apple-relay-renew.service || resume_failed=1
    fi
    if (( INSTALL_TIMER_WAS_ACTIVE == 1 )); then
        systemctl start apple-relay-renew.timer || resume_failed=1
    fi
    return "$resume_failed"
}

read_preinstall_systemd_state() {
    local service_load timer_load renew_load
    service_load="$(systemd_unit_property apple-relay.service LoadState)" || return 1
    timer_load="$(systemd_unit_property apple-relay-renew.timer LoadState)" || return 1
    renew_load="$(systemd_unit_property apple-relay-renew.service LoadState)" || return 1

    if [[ "$service_load" == "not-found" ]]; then
        INSTALL_SERVICE_ACTIVE_STATE="inactive"
        INSTALL_SERVICE_ENABLE_STATE="not-found"
    else
        INSTALL_SERVICE_ACTIVE_STATE="$(systemd_unit_property apple-relay.service ActiveState)" \
            || return 1
        INSTALL_SERVICE_ENABLE_STATE="$(systemd_unit_property apple-relay.service UnitFileState)" \
            || return 1
    fi
    if [[ "$timer_load" == "not-found" ]]; then
        INSTALL_TIMER_ACTIVE_STATE="inactive"
        INSTALL_TIMER_ENABLE_STATE="not-found"
    else
        INSTALL_TIMER_ACTIVE_STATE="$(systemd_unit_property apple-relay-renew.timer ActiveState)" \
            || return 1
        INSTALL_TIMER_ENABLE_STATE="$(systemd_unit_property apple-relay-renew.timer UnitFileState)" \
            || return 1
    fi
    if [[ "$renew_load" == "not-found" ]]; then
        INSTALL_RENEW_ACTIVE_STATE="inactive"
    else
        INSTALL_RENEW_ACTIVE_STATE="$(systemd_unit_property apple-relay-renew.service ActiveState)" \
            || return 1
    fi

    case "$INSTALL_SERVICE_ACTIVE_STATE" in
        active) INSTALL_SERVICE_WAS_ACTIVE=1 ;;
        inactive|failed) INSTALL_SERVICE_WAS_ACTIVE=0 ;;
        *) log_error "Apple Relay service is in a transitional state: ${INSTALL_SERVICE_ACTIVE_STATE}"; return 1 ;;
    esac
    case "$INSTALL_TIMER_ACTIVE_STATE" in
        active) INSTALL_TIMER_WAS_ACTIVE=1 ;;
        inactive|failed) INSTALL_TIMER_WAS_ACTIVE=0 ;;
        *) log_error "Apple Relay timer is in a transitional state: ${INSTALL_TIMER_ACTIVE_STATE}"; return 1 ;;
    esac
    case "$INSTALL_RENEW_ACTIVE_STATE" in
        active|activating) INSTALL_RENEW_SERVICE_WAS_ACTIVE=1 ;;
        inactive|failed) INSTALL_RENEW_SERVICE_WAS_ACTIVE=0 ;;
        *) log_error "Apple Relay renewal job is in an unexpected state: ${INSTALL_RENEW_ACTIVE_STATE}"; return 1 ;;
    esac
    case "$INSTALL_SERVICE_ENABLE_STATE" in
        enabled|enabled-runtime|disabled|not-found) ;;
        *) log_error "Unsupported Apple Relay unit-file state: ${INSTALL_SERVICE_ENABLE_STATE:-empty}"; return 1 ;;
    esac
    case "$INSTALL_TIMER_ENABLE_STATE" in
        enabled|enabled-runtime|disabled|not-found) ;;
        *) log_error "Unsupported Apple Relay timer unit-file state: ${INSTALL_TIMER_ENABLE_STATE:-empty}"; return 1 ;;
    esac
}

snapshot_install_state() {
    INSTALL_SERVICE_WAS_ACTIVE=0
    INSTALL_TIMER_WAS_ACTIVE=0
    INSTALL_RENEW_SERVICE_WAS_ACTIVE=0
    INSTALL_SERVICE_ENABLE_STATE=""
    INSTALL_TIMER_ENABLE_STATE=""
    INSTALL_SERVICE_ACTIVE_STATE=""
    INSTALL_TIMER_ACTIVE_STATE=""
    INSTALL_RENEW_ACTIVE_STATE=""
    INSTALL_SERVICE_USER_EXISTED=0
    INSTALL_SERVICE_GROUP_EXISTED=0
    if id -u "$SERVICE_USER" >/dev/null 2>&1; then
        INSTALL_SERVICE_USER_EXISTED=1
    fi
    if getent group "$SERVICE_USER" >/dev/null 2>&1; then
        INSTALL_SERVICE_GROUP_EXISTED=1
    fi
    read_preinstall_systemd_state || return 1

    if (( INSTALL_TIMER_WAS_ACTIVE == 1 || INSTALL_RENEW_SERVICE_WAS_ACTIVE == 1 )); then
        if ! systemctl stop apple-relay-renew.timer apple-relay-renew.service; then
            log_warn "systemctl reported an error while pausing certificate renewal; verifying the final state."
        fi
        INSTALL_TIMER_ACTIVE_STATE="$(systemd_unit_property apple-relay-renew.timer ActiveState)" \
            || { resume_preinstall_renewal_state || true; return 1; }
        INSTALL_RENEW_ACTIVE_STATE="$(systemd_unit_property apple-relay-renew.service ActiveState)" \
            || { resume_preinstall_renewal_state || true; return 1; }
    fi
    if [[ "$INSTALL_TIMER_ACTIVE_STATE" != "inactive" \
        && "$INSTALL_TIMER_ACTIVE_STATE" != "failed" ]] \
        || [[ "$INSTALL_RENEW_ACTIVE_STATE" != "inactive" \
            && "$INSTALL_RENEW_ACTIVE_STATE" != "failed" ]]; then
        log_error "Could not pause certificate renewal before creating the rollback snapshot."
        resume_preinstall_renewal_state || true
        return 1
    fi

    if ! INSTALL_BACKUP_DIR="$(mktemp -d /tmp/apple-relay-install-backup.XXXXXX)"; then
        INSTALL_BACKUP_DIR=""
        resume_preinstall_renewal_state || true
        return 1
    fi
    if ! backup_install_path "$CONFIG_DIR" "${INSTALL_BACKUP_DIR}/config" \
        || ! backup_install_path "$BASE_DIR" "${INSTALL_BACKUP_DIR}/base" \
        || ! backup_install_path "$STATE_DIR" "${INSTALL_BACKUP_DIR}/state" \
        || ! backup_install_path "$LAUNCHER_PATH" "${INSTALL_BACKUP_DIR}/relayctl-launcher" \
        || ! backup_install_path "$SERVICE_UNIT" "${INSTALL_BACKUP_DIR}/apple-relay.service" \
        || ! backup_install_path "$RENEW_SERVICE_UNIT" "${INSTALL_BACKUP_DIR}/apple-relay-renew.service" \
        || ! backup_install_path "$RENEW_TIMER_UNIT" "${INSTALL_BACKUP_DIR}/apple-relay-renew.timer"; then
        cleanup_install_backup || true
        resume_preinstall_renewal_state || true
        return 1
    fi
}

restore_install_file() {
    local backup="$1"
    local destination="$2"
    if [[ -e "$destination" || -L "$destination" ]]; then
        rm -f -- "$destination" || return 1
    fi
    if [[ -e "$backup" || -L "$backup" ]]; then
        cp -a -- "$backup" "$destination" || return 1
    fi
}

restore_unit_enable_state() {
    local unit_name="$1"
    local previous_state="$2"
    local current_state
    case "$previous_state" in
        enabled)
            systemctl enable "$unit_name" >/dev/null || return 1
            current_state="$(systemd_unit_property "$unit_name" UnitFileState)" || return 1
            [[ "$current_state" == "enabled" ]]
            ;;
        enabled-runtime)
            systemctl enable --runtime "$unit_name" >/dev/null || return 1
            current_state="$(systemd_unit_property "$unit_name" UnitFileState)" || return 1
            [[ "$current_state" == "enabled-runtime" ]]
            ;;
        disabled)
            systemctl disable "$unit_name" >/dev/null 2>&1 || true
            current_state="$(systemd_unit_property "$unit_name" UnitFileState)" || return 1
            [[ "$current_state" == "disabled" ]]
            ;;
        not-found)
            systemctl disable "$unit_name" >/dev/null 2>&1 || true
            current_state="$(systemd_unit_property "$unit_name" LoadState)" || return 1
            [[ "$current_state" == "not-found" ]]
            ;;
        *)
            log_error "Unsupported previous enable state '${previous_state:-empty}' for ${unit_name}."
            return 1
            ;;
    esac
}

remove_new_install_directory() {
    local path="$1"
    local existed_before="$2"
    local label="$3"
    (( existed_before == 0 )) || return 0
    [[ -e "$path" || -L "$path" ]] || return 0
    if ! is_managed_dir "$path"; then
        log_error "The newly created ${label} directory is no longer safely managed: ${path}"
        return 1
    fi
    remove_managed_dir "$path"
}

cleanup_install_bootstrap_on_exit() {
    (( INSTALL_BOOTSTRAP_CLEANUP_ACTIVE == 1 )) || return 0
    INSTALL_BOOTSTRAP_CLEANUP_ACTIVE=0
    log_warn "Installation stopped before the runtime transaction; removing newly created bootstrap files."
    remove_new_install_directory "$BASE_DIR" "$INSTALL_BASE_PREEXISTED" runtime || true
    remove_new_install_directory "$CONFIG_DIR" "$INSTALL_CONFIG_PREEXISTED" configuration || true
    remove_new_install_directory "$STATE_DIR" "$INSTALL_STATE_PREEXISTED" state || true
}

restore_install_state() {
    local rollback_failed=0 service_state renew_state timer_state
    log_warn "The installation failed; restoring the previous Apple Relay state."

    if ! systemctl stop apple-relay-renew.timer apple-relay-renew.service apple-relay.service; then
        log_warn "systemctl reported an error while stopping the failed runtime; verifying the final state."
    fi
    systemctl disable apple-relay-renew.timer apple-relay.service >/dev/null 2>&1 || true

    service_state="$(systemd_effective_active_state apple-relay.service)" || return 1
    renew_state="$(systemd_effective_active_state apple-relay-renew.service)" || return 1
    timer_state="$(systemd_effective_active_state apple-relay-renew.timer)" || return 1
    if [[ "$service_state" != "inactive" && "$service_state" != "failed" ]] \
        || [[ "$renew_state" != "inactive" && "$renew_state" != "failed" ]] \
        || [[ "$timer_state" != "inactive" && "$timer_state" != "failed" ]]; then
        log_error "A new Apple Relay process is still active; rollback cannot safely replace its files."
        log_error "Automatic rollback was not attempted. The rollback snapshot was preserved at ${INSTALL_BACKUP_DIR}."
        return 1
    fi

    if [[ -e "$BASE_DIR" ]]; then
        if is_managed_dir "$BASE_DIR"; then
            if ! remove_managed_dir "$BASE_DIR"; then
                rollback_failed=1
                log_error "The current runtime directory could not be removed during rollback."
            fi
        else
            rollback_failed=1
            log_error "The current runtime directory is unowned; refusing to replace it during rollback."
        fi
    fi
    if [[ ! -e "$BASE_DIR" && ! -L "$BASE_DIR" \
        && (-e "${INSTALL_BACKUP_DIR}/base" || -L "${INSTALL_BACKUP_DIR}/base") ]]; then
        cp -a -- "${INSTALL_BACKUP_DIR}/base" "$BASE_DIR" || rollback_failed=1
    elif [[ -e "$BASE_DIR" || -L "$BASE_DIR" ]]; then
        rollback_failed=1
    fi
    restore_install_file "${INSTALL_BACKUP_DIR}/relayctl-launcher" "$LAUNCHER_PATH" \
        || rollback_failed=1

    if [[ -e "$CONFIG_DIR" || -L "$CONFIG_DIR" ]]; then
        if is_managed_dir "$CONFIG_DIR"; then
            if ! remove_managed_dir "$CONFIG_DIR"; then
                rollback_failed=1
                log_error "The current configuration directory could not be removed during rollback."
            fi
        else
            rollback_failed=1
            log_error "The current configuration directory is unowned; refusing to replace it during rollback."
        fi
    fi
    if [[ ! -e "$CONFIG_DIR" && ! -L "$CONFIG_DIR" \
        && (-e "${INSTALL_BACKUP_DIR}/config" || -L "${INSTALL_BACKUP_DIR}/config") ]]; then
        cp -a -- "${INSTALL_BACKUP_DIR}/config" "$CONFIG_DIR" || rollback_failed=1
    elif [[ -e "$CONFIG_DIR" || -L "$CONFIG_DIR" ]]; then
        rollback_failed=1
    fi

    if [[ -e "$STATE_DIR" || -L "$STATE_DIR" ]]; then
        if is_managed_dir "$STATE_DIR"; then
            if ! remove_managed_dir "$STATE_DIR"; then
                rollback_failed=1
                log_error "The current state directory could not be removed during rollback."
            fi
        else
            rollback_failed=1
            log_error "The current state directory is unowned; refusing to replace it during rollback."
        fi
    fi
    if (( INSTALL_SERVICE_USER_EXISTED == 0 )) && id -u "$SERVICE_USER" >/dev/null 2>&1; then
        userdel "$SERVICE_USER" >/dev/null 2>&1 || rollback_failed=1
    fi
    if (( INSTALL_SERVICE_GROUP_EXISTED == 0 )) && getent group "$SERVICE_USER" >/dev/null 2>&1; then
        groupdel "$SERVICE_USER" >/dev/null 2>&1 || rollback_failed=1
    fi
    if [[ ! -e "$STATE_DIR" && ! -L "$STATE_DIR" \
        && (-e "${INSTALL_BACKUP_DIR}/state" || -L "${INSTALL_BACKUP_DIR}/state") ]]; then
        cp -a -- "${INSTALL_BACKUP_DIR}/state" "$STATE_DIR" || rollback_failed=1
    elif [[ -e "$STATE_DIR" || -L "$STATE_DIR" ]]; then
        rollback_failed=1
    fi

    remove_new_install_directory "$BASE_DIR" "$INSTALL_BASE_PREEXISTED" runtime \
        || rollback_failed=1
    remove_new_install_directory "$CONFIG_DIR" "$INSTALL_CONFIG_PREEXISTED" configuration \
        || rollback_failed=1
    remove_new_install_directory "$STATE_DIR" "$INSTALL_STATE_PREEXISTED" state \
        || rollback_failed=1

    restore_install_file "${INSTALL_BACKUP_DIR}/apple-relay.service" "$SERVICE_UNIT" \
        || rollback_failed=1
    restore_install_file "${INSTALL_BACKUP_DIR}/apple-relay-renew.service" "$RENEW_SERVICE_UNIT" \
        || rollback_failed=1
    restore_install_file "${INSTALL_BACKUP_DIR}/apple-relay-renew.timer" "$RENEW_TIMER_UNIT" \
        || rollback_failed=1
    systemctl daemon-reload || rollback_failed=1

    restore_unit_enable_state apple-relay.service "$INSTALL_SERVICE_ENABLE_STATE" \
        || rollback_failed=1
    restore_unit_enable_state apple-relay-renew.timer "$INSTALL_TIMER_ENABLE_STATE" \
        || rollback_failed=1

    if (( rollback_failed == 0 && INSTALL_SERVICE_WAS_ACTIVE == 1 )); then
        if validate_saved_environment; then
            if restart_relay_service; then
                log_ok "The previous Apple Relay service was restored."
            else
                rollback_failed=1
                log_error "The previous files were restored, but the Apple Relay service did not restart."
            fi
        else
            log_warn "The restored relay.env is invalid (${ENVIRONMENT_ERROR}); checking the restored service through systemd only."
            systemctl reset-failed apple-relay.service >/dev/null 2>&1 || true
            if systemctl restart apple-relay.service \
                && sleep 1 \
                && systemctl is-active --quiet apple-relay.service; then
                log_ok "The previous Apple Relay process was restored despite its invalid management configuration."
            else
                rollback_failed=1
                log_error "The previous files were restored, but the Apple Relay service did not restart."
                journalctl -u apple-relay.service -n 100 --no-pager >&2 || true
            fi
        fi
    fi
    if (( rollback_failed == 0 && INSTALL_RENEW_SERVICE_WAS_ACTIVE == 1 )); then
        if ! systemctl start apple-relay-renew.service; then
            rollback_failed=1
            log_error "The previous certificate renewal job could not be restarted."
        fi
    fi
    if (( rollback_failed == 0 && INSTALL_TIMER_WAS_ACTIVE == 1 )); then
        if ! systemctl start apple-relay-renew.timer; then
            rollback_failed=1
            log_error "The previous certificate renewal timer could not be restarted."
        fi
    fi

    if (( rollback_failed == 0 )); then
        if ! cleanup_install_backup; then
            rollback_failed=1
            log_error "The previous state was restored, but the rollback snapshot could not be removed."
        fi
    else
        log_error "Automatic rollback was incomplete. The rollback snapshot was preserved at ${INSTALL_BACKUP_DIR}."
    fi
    return "$rollback_failed"
}

process_identity() {
    local process_id="$1"
    local stat_line remainder
    local fields=()
    [[ -r "/proc/${process_id}/stat" ]] || return 1
    stat_line="$(<"/proc/${process_id}/stat")"
    remainder="${stat_line##*) }"
    read -r -a fields <<<"$remainder"
    [[ -n "${fields[1]:-}" && -n "${fields[19]:-}" ]] || return 1
    printf '%s:%s\n' "${fields[1]}" "${fields[19]}"
}

collect_install_process_tree() {
    local process_id="$1"
    local expected_parent="${2:-}"
    local child_id children_file children="" identity_before identity_after seen=" "
    identity_before="$(process_identity "$process_id")" || return 0
    if [[ -n "$expected_parent" \
        && "${identity_before%%:*}" != "$expected_parent" ]]; then
        return 0
    fi
    kill -STOP "$process_id" 2>/dev/null || return 0
    identity_after="$(process_identity "$process_id")" || {
        kill -CONT "$process_id" 2>/dev/null || true
        return 0
    }
    if [[ "$identity_before" != "$identity_after" ]]; then
        kill -CONT "$process_id" 2>/dev/null || true
        return 0
    fi
    INSTALL_PROCESS_TREE_PIDS+=("$process_id")
    INSTALL_PROCESS_TREE_IDENTITIES+=("${identity_after#*:}")
    for children_file in "/proc/${process_id}"/task/*/children; do
        [[ -r "$children_file" ]] || continue
        children=""
        read -r children <"$children_file" || true
        for child_id in $children; do
            if [[ "$seen" != *" ${child_id} "* ]]; then
                seen+="${child_id} "
                collect_install_process_tree "$child_id" "$process_id"
            fi
        done
    done
}

install_process_identity_matches() {
    local index="$1"
    local current_identity
    current_identity="$(process_identity "${INSTALL_PROCESS_TREE_PIDS[$index]}")" || return 1
    [[ "${current_identity#*:}" == "${INSTALL_PROCESS_TREE_IDENTITIES[$index]}" ]]
}

terminate_install_process_tree() {
    local index process_id
    INSTALL_PROCESS_TREE_PIDS=()
    INSTALL_PROCESS_TREE_IDENTITIES=()
    collect_install_process_tree "$1"
    for ((index = ${#INSTALL_PROCESS_TREE_PIDS[@]} - 1; index >= 0; index--)); do
        install_process_identity_matches "$index" || continue
        process_id="${INSTALL_PROCESS_TREE_PIDS[$index]}"
        kill -TERM "$process_id" 2>/dev/null || true
        kill -CONT "$process_id" 2>/dev/null || true
    done
    sleep 1
    for index in "${!INSTALL_PROCESS_TREE_PIDS[@]}"; do
        install_process_identity_matches "$index" || continue
        process_id="${INSTALL_PROCESS_TREE_PIDS[$index]}"
        kill -KILL "$process_id" 2>/dev/null || true
    done
}

interrupt_install_transaction() {
    local signal_name="$1"
    INSTALL_INTERRUPTED_SIGNAL="$signal_name"
    if [[ "$INSTALL_APPLY_PID" =~ ^[0-9]+$ ]]; then
        terminate_install_process_tree "$INSTALL_APPLY_PID"
    fi
}

apply_install_configuration() {
    prepare_runtime_installation
    if (( REUSE_EXISTING_CONFIG == 0 )); then
        save_environment
    fi
    if [[ ! -s "$TOKEN_FILE" ]]; then
        random_token | write_atomic "$TOKEN_FILE" 600
    fi
    ensure_letsencrypt_certificate
    if (( REUSE_EXISTING_CONFIG == 0 || REBUILD_EXISTING_ENVOY_CONFIG == 1 )); then
        render_envoy_config
    fi
    secure_runtime_files
    if ! validate_envoy_config; then
        if (( REUSE_EXISTING_CONFIG == 1 && REBUILD_EXISTING_ENVOY_CONFIG == 0 )); then
            log_warn "The preserved Envoy configuration is incompatible with the new runtime and will be rebuilt."
            render_envoy_config
            secure_runtime_files
            validate_envoy_config
        else
            return 1
        fi
    fi
    install_systemd_units
    restart_relay_service \
        || { log_error "Apple Relay failed to start."; return 1; }
    if ! systemctl enable --now apple-relay-renew.timer >/dev/null; then
        log_error "Apple Relay started, but the certificate renewal timer could not be enabled."
        return 1
    fi
}

collect_install_configuration() {
    local value detected_public_ipv4
    while true; do
        value="$(prompt_input "Relay domain:")"
        value="${value,,}"
        if is_valid_domain "$value"; then
            DOMAIN="$value"
            break
        fi
        log_warn "Enter a valid fully qualified domain name."
    done

    detected_public_ipv4="$(detect_public_ipv4)"
    while true; do
        value="$(prompt_input "Public IPv4 for the DNS A record:" "${PUBLIC_IPV4:-$detected_public_ipv4}")"
        if is_valid_ipv4 "$value"; then
            PUBLIC_IPV4="$value"
            break
        fi
        log_warn "Enter a globally routable IPv4 address."
    done

    LISTEN_ADDRESS="0.0.0.0"
    LISTEN_PORT="443"

    while true; do
        CERT_EMAIL="$(prompt_input "Let's Encrypt account email:" "${CERT_EMAIL:-}")"
        [[ "$CERT_EMAIL" == *@*.* && "$CERT_EMAIL" != *$'\n'* && "$CERT_EMAIL" != *$'\r'* ]] && break
        log_warn "Enter a valid email address."
    done
}

install_relay() {
    require_root
    attach_tty
    require_tty
    install_base_dependencies

    PREVIOUS_INSTALLATION_DETECTED=0
    EXISTING_CONFIG_INVALID=0
    EXISTING_CONFIG_ERROR=""
    EXISTING_TOKEN_INVALID=0
    EXISTING_TOKEN_ERROR=""
    REUSE_EXISTING_CONFIG=0
    REBUILD_EXISTING_ENVOY_CONFIG=0
    INSTALL_BASE_PREEXISTED=0
    INSTALL_CONFIG_PREEXISTED=0
    INSTALL_STATE_PREEXISTED=0
    [[ -e "$BASE_DIR" || -L "$BASE_DIR" ]] && INSTALL_BASE_PREEXISTED=1
    [[ -e "$CONFIG_DIR" || -L "$CONFIG_DIR" ]] && INSTALL_CONFIG_PREEXISTED=1
    [[ -e "$STATE_DIR" || -L "$STATE_DIR" ]] && INSTALL_STATE_PREEXISTED=1
    INSTALL_BOOTSTRAP_CLEANUP_ACTIVE=1
    trap cleanup_install_bootstrap_on_exit EXIT
    detect_previous_installation
    if [[ -e "$CONFIG_DIR" || -L "$CONFIG_DIR" ]]; then
        is_managed_dir "$CONFIG_DIR" \
            || die "Refusing to inspect or replace an unowned configuration directory: ${CONFIG_DIR}"
        assert_existing_tls_layout_safe
    fi

    local previous_listen_port=""
    local previous_admin_port=""
    if [[ -f "$ENV_FILE" ]]; then
        if assess_existing_configuration; then
            previous_listen_port="$LISTEN_PORT"
            previous_admin_port="$ADMIN_PORT"
        else
            log_warn "Existing configuration validation failed: ${EXISTING_CONFIG_ERROR}"
        fi
    elif [[ -d "$CONFIG_DIR" ]] \
        && find "$CONFIG_DIR" -mindepth 1 -maxdepth 1 ! -name "$OWNERSHIP_MARKER" -print -quit \
            | grep -q .; then
        validate_existing_project_configuration || true
        EXISTING_CONFIG_INVALID=1
        EXISTING_CONFIG_ERROR="The configuration directory exists, but relay.env is missing."
        log_warn "Existing configuration validation failed: ${EXISTING_CONFIG_ERROR}"
        if (( EXISTING_TOKEN_INVALID == 1 )); then
            log_warn "${EXISTING_TOKEN_ERROR} A new token will be generated."
        fi
    fi

    claim_project_dirs
    install_gum
    if (( PREVIOUS_INSTALLATION_DETECTED == 1 )); then
        log_info "A previous managed Apple Relay runtime was detected and will be replaced after validation."
    fi
    if (( REUSE_EXISTING_CONFIG == 1 )); then
        log_info "Validated existing configuration for ${DOMAIN}; it will be preserved during the runtime upgrade."
    else
        DOMAIN=""
        LISTEN_ADDRESS="0.0.0.0"
        LISTEN_PORT="443"
        ADMIN_PORT="9901"
        PUBLIC_IPV4=""
        CERT_EMAIL=""
        collect_install_configuration
    fi
    wait_for_dns
    if (( PREVIOUS_INSTALLATION_DETECTED == 0 )); then
        preflight_ports "$previous_listen_port" "$previous_admin_port"
    fi

    local install_status=0
    INSTALL_INTERRUPTED_SIGNAL=""
    INSTALL_APPLY_PID=""
    trap 'interrupt_install_transaction INT' INT
    trap 'interrupt_install_transaction TERM' TERM
    trap 'interrupt_install_transaction HUP' HUP
    if ! snapshot_install_state; then
        trap - INT TERM HUP
        die "Could not create a rollback snapshot; no existing runtime was removed."
    fi
    if [[ -n "$INSTALL_INTERRUPTED_SIGNAL" ]]; then
        resume_preinstall_renewal_state || true
        cleanup_install_backup || true
        trap - INT TERM HUP
        die "Installation was interrupted by ${INSTALL_INTERRUPTED_SIGNAL} before the previous runtime was removed."
    fi
    INSTALL_BOOTSTRAP_CLEANUP_ACTIVE=0
    trap - EXIT
    if [[ -z "$INSTALL_INTERRUPTED_SIGNAL" ]]; then
        set +e
        (
            set -Eeuo pipefail
            apply_install_configuration
        ) &
        INSTALL_APPLY_PID=$!
        if [[ -n "$INSTALL_INTERRUPTED_SIGNAL" ]]; then
            terminate_install_process_tree "$INSTALL_APPLY_PID"
        fi
        while true; do
            wait "$INSTALL_APPLY_PID"
            install_status=$?
            if ! kill -0 "$INSTALL_APPLY_PID" 2>/dev/null; then
                break
            fi
        done
        set -e
    else
        install_status=130
    fi
    INSTALL_APPLY_PID=""
    if [[ -n "$INSTALL_INTERRUPTED_SIGNAL" ]]; then
        log_warn "Installation was interrupted by ${INSTALL_INTERRUPTED_SIGNAL}; rolling back."
        install_status=130
    fi
    if (( install_status != 0 )); then
        if restore_install_state; then
            trap - INT TERM HUP
            die "Installation failed, and the previous Apple Relay state was restored. Review the error shown above."
        fi
        trap - INT TERM HUP
        die "Installation failed, and automatic rollback was incomplete. Review the errors above; the rollback snapshot is at ${INSTALL_BACKUP_DIR}."
    fi
    cleanup_install_backup \
        || log_warn "The installation succeeded, but its temporary rollback snapshot could not be removed."
    trap - INT TERM HUP

    local token
    token="$(cat "$TOKEN_FILE")"
    {
        printf 'Apple Relay is ready.\n\n'
        printf 'Relay domain: %s\n' "$DOMAIN"
        printf 'Header: X-Relay-Token: %s\n\n' "$token"
        printf 'The token is shown now and stored at %s (root-only).\n' "$TOKEN_FILE"
    } | "$GUM_BIN" style --border rounded --padding "1 2" --border-foreground 212
}

show_status() {
    require_root
    load_environment || die "Apple Relay is not configured."
    local service_state timer_state expires fingerprint
    service_state="$(systemctl is-active apple-relay.service 2>/dev/null || true)"
    timer_state="$(systemctl is-active apple-relay-renew.timer 2>/dev/null || true)"
    expires="$(openssl x509 -in "${TLS_DIR}/fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2- || true)"
    fingerprint="$(openssl x509 -in "${TLS_DIR}/fullchain.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2- || true)"
    cat <<EOF
Service:       ${service_state:-unknown}
Endpoint:      ${LISTEN_ADDRESS}:${LISTEN_PORT} (HTTP/2 CONNECT + CONNECT-UDP)
Relay domain:  ${DOMAIN}
Public IPv4:   ${PUBLIC_IPV4} (verified through 1.1.1.1)
Certificate:   Let's Encrypt HTTP-01
Cert expires:  ${expires:-unknown}
SHA-256:       ${fingerprint:-unknown}
Renew timer:   ${timer_state:-not-enabled}
Envoy version: ${ENVOY_VERSION}
EOF
}

restart_relay() {
    require_root
    load_environment || die "Apple Relay is not configured."
    validate_envoy_config
    restart_relay_service \
        || die "Apple Relay failed to restart. The service logs for this attempt are shown above."
    log_ok "Apple Relay restarted."
}

rotate_token() {
    require_root
    attach_tty
    require_tty
    install_gum
    load_environment || die "Apple Relay is not configured."
    confirm "Rotate the relay token? Existing client profiles will stop working immediately." || return 0

    local old_token new_token
    old_token="$(cat "$TOKEN_FILE")"
    new_token="$(random_token)"
    printf '%s\n' "$new_token" | write_atomic "$TOKEN_FILE" 600
    if ! render_envoy_config || ! validate_envoy_config; then
        printf '%s\n' "$old_token" | write_atomic "$TOKEN_FILE" 600
        render_envoy_config
        die "Token rotation failed validation; the old token was restored."
    fi
    if ! restart_relay_service; then
        printf '%s\n' "$old_token" | write_atomic "$TOKEN_FILE" 600
        if ! render_envoy_config || ! validate_envoy_config || ! restart_relay_service; then
            die "Token rotation failed. The old token was restored, but Apple Relay could not be returned to a running state; review the errors above."
        fi
        die "Token rotation failed; the old token was restored."
    fi

    {
        printf 'The relay token was rotated.\n\n'
        printf 'X-Relay-Token: %s\n\n' "$new_token"
        printf 'Update every client profile. The old token no longer works.\n'
    } | "$GUM_BIN" style --border rounded --padding "1 2" --border-foreground 212
}

renew_certificate() {
    require_root
    local quiet=0
    [[ "${1:-}" == "--quiet" ]] && quiet=1
    load_environment || die "Apple Relay is not configured."
    require_dns_points_to_relay "Certificate renewal"
    install_certbot
    local old_hash new_hash
    old_hash="$(sha256_file "${TLS_DIR}/fullchain.pem")"
    certbot renew --cert-name "$DOMAIN" --quiet
    copy_letsencrypt_lineage
    new_hash="$(sha256_file "${TLS_DIR}/fullchain.pem")"
    if [[ "$old_hash" != "$new_hash" ]]; then
        validate_envoy_config
        restart_relay_service \
            || die "The certificate was renewed, but Apple Relay failed to restart; the service logs are shown above."
        (( quiet == 1 )) || log_ok "The certificate was renewed and Apple Relay was restarted."
    else
        (( quiet == 1 )) || log_info "The certificate is not due for renewal."
    fi
}

reissue_certificate() {
    require_root
    attach_tty
    require_tty
    install_gum
    load_environment || die "Apple Relay is not configured."
    confirm "Force a new Let's Encrypt certificate through HTTP-01?" || return 0
    require_dns_points_to_relay "Certificate reissuance"
    issue_letsencrypt_certificate 1
    validate_envoy_config
    restart_relay_service \
        || die "The new certificate was issued, but Apple Relay failed to restart; the service logs are shown above."
    log_ok "A new certificate was issued and Apple Relay was restarted."
}

show_logs() {
    require_root
    journalctl -u apple-relay.service -n 100 --no-pager
}

uninstall_relay() {
    require_root
    local mode="${1:-keep}"
    local assume_yes="${2:-}"
    local remove_service_user=0
    [[ -f "$SERVICE_USER_MARKER" ]] && remove_service_user=1
    [[ "$mode" =~ ^(keep|purge|decommission)$ ]] || die "Unknown uninstall mode: ${mode}"

    if [[ "$assume_yes" != "--yes" ]]; then
        attach_tty
        require_tty
        install_gum
        confirm "Uninstall Apple Relay (${mode})?" || return 0
    fi
    load_environment || true

    systemctl disable --now apple-relay.service apple-relay-renew.timer >/dev/null 2>&1 || true
    rm -f "$SERVICE_UNIT" "$RENEW_SERVICE_UNIT" "$RENEW_TIMER_UNIT" "$LAUNCHER_PATH"
    systemctl daemon-reload

    if [[ "$mode" == "decommission" && -n "${DOMAIN:-}" ]] && command_exists certbot; then
        certbot delete --cert-name "$DOMAIN" --non-interactive >/dev/null 2>&1 || \
            log_warn "The Let's Encrypt lineage could not be deleted automatically."
    fi
    if [[ "$mode" =~ ^(purge|decommission)$ ]]; then
        remove_managed_dir "$CONFIG_DIR"
    fi
    remove_managed_dir "$STATE_DIR"
    remove_managed_dir "$BASE_DIR"
    if [[ "$remove_service_user" == "1" ]]; then
        userdel "$SERVICE_USER" >/dev/null 2>&1 || true
        groupdel "$SERVICE_USER" >/dev/null 2>&1 || true
    fi
    log_ok "Apple Relay was uninstalled."
    if [[ "$mode" == "keep" ]]; then
        log_info "Configuration was kept at ${CONFIG_DIR}."
    fi
    return 0
}

manage_menu() {
    require_root
    claim_project_dirs
    attach_tty
    require_tty
    install_base_dependencies
    install_gum
    while true; do
        local selection
        if [[ -f "$ENV_FILE" ]]; then
            selection="$(choose "Apple Relay management" \
                "Status" \
                "Restart" \
                "Rotate token" \
                "Renew certificate" \
                "Reissue certificate" \
                "View logs" \
                "Reconfigure / reinstall" \
                "Uninstall (keep configuration)" \
                "Uninstall and purge" \
                "Uninstall and decommission certificate" \
                "Quit")" || return 0
        else
            selection="$(choose "Apple Relay" "Install" "Quit")" || return 0
        fi
        case "$selection" in
            "Install"|"Reconfigure / reinstall") install_relay; return 0 ;;
            "Status") show_status | "$GUM_BIN" pager ;;
            "Restart") restart_relay ;;
            "Rotate token") rotate_token ;;
            "Renew certificate") renew_certificate ;;
            "Reissue certificate") reissue_certificate ;;
            "View logs") show_logs | "$GUM_BIN" pager ;;
            "Uninstall (keep configuration)") uninstall_relay keep; return 0 ;;
            "Uninstall and purge") uninstall_relay purge; return 0 ;;
            "Uninstall and decommission certificate") uninstall_relay decommission; return 0 ;;
            "Quit"|"") return 0 ;;
        esac
    done
}

usage() {
    cat <<EOF
Apple Relay manager ${PROJECT_VERSION}

Usage:
  relayctl                         Open the Gum management interface
  relayctl install                 Install or reconfigure Apple Relay
  relayctl status                  Show service and certificate status
  relayctl restart                 Validate configuration and restart
  relayctl rotate-token            Rotate X-Relay-Token interactively
  relayctl renew-cert [--quiet]    Run a Let's Encrypt renewal check
  relayctl reissue-cert            Force a new HTTP-01 certificate
  relayctl logs                    Show recent service logs
  relayctl uninstall [mode]        Uninstall; mode: keep, purge, decommission
  relayctl help                    Show this help

Direct uninstall accepts a second --yes argument for explicit automation.
EOF
}

main() {
    local command="${1:-menu}"
    case "$command" in
        menu) manage_menu ;;
        install) install_relay ;;
        status) show_status ;;
        restart) restart_relay ;;
        rotate-token) rotate_token ;;
        renew-cert) renew_certificate "${2:-}" ;;
        reissue-cert) reissue_certificate ;;
        logs) show_logs ;;
        uninstall) uninstall_relay "${2:-keep}" "${3:-}" ;;
        help|-h|--help) usage ;;
        *) usage >&2; exit 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]; then
    main "$@"
fi
