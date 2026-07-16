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
    [[ -d "$path" && ! -L "$path" && -f "$marker" && ! -L "$marker" ]] || return 1
    [[ "$(stat -c %u "$path" 2>/dev/null)" == "0" ]] || return 1
    [[ "$(stat -c %u "$marker" 2>/dev/null)" == "0" ]] || return 1
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
        if find "$path" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
            die "Refusing to claim non-empty unowned directory: ${path}"
        fi
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
    if [[ ! -e "$path" ]]; then
        return 0
    fi
    if is_managed_dir "$path"; then
        rm -rf -- "$path"
    else
        log_warn "Preserving unowned or unsafe directory: ${path}"
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

load_environment() {
    [[ -f "$ENV_FILE" ]] || return 1
    [[ ! -L "$ENV_FILE" && "$(stat -c %u "$ENV_FILE" 2>/dev/null)" == "0" ]] \
        || die "The saved environment file is not a safe root-owned regular file."
    local env_mode
    env_mode="$(stat -c %a "$ENV_FILE")"
    (( (8#$env_mode & 022) == 0 )) \
        || die "The saved environment file is writable by a non-root user."
    # The file is root-owned, mode 0600, and every value is written with shell escaping.
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    is_valid_domain "$DOMAIN" || die "The saved relay domain is invalid."
    is_valid_ip "$LISTEN_ADDRESS" || die "The saved listen address is invalid."
    is_valid_port "$LISTEN_PORT" || die "The saved listen port is invalid."
    is_valid_port "$ADMIN_PORT" || die "The saved admin port is invalid."
    is_valid_ipv4 "$PUBLIC_IPV4" || die "The saved public IPv4 address is invalid."
    [[ "$CERT_EMAIL" == *@*.* && "$CERT_EMAIL" != *$'\n'* && "$CERT_EMAIL" != *$'\r'* ]] \
        || die "The saved Let's Encrypt account email is invalid."
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
        "$GUM_BIN" spin --spinner dot --title "$title" -- "$@"
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
    if command_exists gum; then
        local system_gum
        system_gum="$(command -v gum)"
        install -m 0755 "$system_gum" "$GUM_BIN"
        return 0
    fi
    if have_gum; then
        return 0
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
try:
    sock.bind((address, int(raw_port)))
except OSError:
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
            || die "TCP ${LISTEN_ADDRESS}:${LISTEN_PORT} is already in use."
    fi
    if [[ "$service_active" != "1" || "$ADMIN_PORT" != "$previous_admin_port" ]]; then
        port_is_available tcp 127.0.0.1 "$ADMIN_PORT" \
            || die "TCP 127.0.0.1:${ADMIN_PORT} is already in use."
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

query_cloudflare_dns() {
    local record_type="$1"
    local response
    response="$(curl -4fsS --connect-timeout 5 --max-time 15 \
        -H 'accept: application/dns-json' \
        "https://1.1.1.1/dns-query?name=${DOMAIN}&type=${record_type}" 2>/dev/null || true)"
    python3 - "$record_type" "$response" <<'PY'
import json
import sys

record_type, raw = sys.argv[1:]
wanted = {"A": 1, "AAAA": 28}[record_type]
try:
    payload = json.loads(raw)
except (TypeError, ValueError):
    raise SystemExit(0)

if payload.get("Status") != 0:
    raise SystemExit(0)

for answer in payload.get("Answer", []):
    if answer.get("type") == wanted and isinstance(answer.get("data"), str):
        print(answer["data"])
PY
}

resolved_a_records() {
    query_cloudflare_dns A \
        | awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}$/ {print}' \
        | sort -u
}

resolved_aaaa_records() {
    query_cloudflare_dns AAAA \
        | awk '/:/ {print}' \
        | sort -u
}

dns_points_to_relay() {
    local a_records aaaa_records
    a_records="$(resolved_a_records)"
    aaaa_records="$(resolved_aaaa_records)"
    [[ "$a_records" == "$PUBLIC_IPV4" && -z "$aaaa_records" ]]
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
    local attempt a_records aaaa_records
    show_dns_instructions
    confirm "The DNS record is configured. Start the 1.1.1.1 propagation check?" \
        || die "DNS validation was cancelled."

    for attempt in $(seq 1 60); do
        if dns_points_to_relay; then
            log_ok "1.1.1.1 resolves ${DOMAIN} to ${PUBLIC_IPV4} with no AAAA record."
            return 0
        fi
        if (( attempt == 1 || attempt % 6 == 0 )); then
            a_records="$(resolved_a_records | paste -sd, -)"
            aaaa_records="$(resolved_aaaa_records | paste -sd, -)"
            log_info "Waiting for DNS propagation via 1.1.1.1 (A=${a_records:-none}, AAAA=${aaaa_records:-none})."
        fi
        sleep 5
    done
    die "DNS validation timed out. 1.1.1.1 must return only A=${PUBLIC_IPV4} for ${DOMAIN}, with no AAAA record."
}

certificate_matches_key() {
    local certificate="$1"
    local private_key="$2"
    local cert_hash key_hash
    cert_hash="$(openssl x509 -in "$certificate" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    key_hash="$(openssl pkey -in "$private_key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    [[ -n "$cert_hash" && "$cert_hash" == "$key_hash" ]]
}

validate_certificate_pair() {
    local certificate="$1"
    local private_key="$2"
    [[ -s "$certificate" && -s "$private_key" ]] || return 1
    openssl x509 -in "$certificate" -noout -checkend 0 >/dev/null \
        || return 1
    certificate_matches_key "$certificate" "$private_key" \
        || return 1
    openssl x509 -in "$certificate" -noout -checkhost "$DOMAIN" >/dev/null \
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
    local lineage="/etc/letsencrypt/live/${DOMAIN}"
    [[ -s "${lineage}/fullchain.pem" && -s "${lineage}/privkey.pem" ]] \
        || die "The Let's Encrypt lineage for ${DOMAIN} is missing."
    copy_certificate "${lineage}/fullchain.pem" "${lineage}/privkey.pem"
}

issue_letsencrypt_certificate() {
    local force="${1:-0}"
    install_certbot
    port_is_available tcp "$LISTEN_ADDRESS" 80 \
        || die "TCP ${LISTEN_ADDRESS}:80 is required for the HTTP-01 challenge."
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
    } | write_atomic "$ENVOY_CONFIG" 600
    if id -u "$SERVICE_USER" >/dev/null 2>&1; then
        chown "root:${SERVICE_USER}" "$ENVOY_CONFIG"
        chmod 0640 "$ENVOY_CONFIG"
    fi
}

validate_envoy_config() {
    [[ -x "$ENVOY_BIN" ]] || die "The Envoy binary is missing."
    local validation_log
    validation_log="$(mktemp /tmp/apple-relay-envoy-validate.XXXXXX)"
    if ! "$ENVOY_BIN" --mode validate -c "$ENVOY_CONFIG" >"$validation_log" 2>&1; then
        cat "$validation_log" >&2
        rm -f "$validation_log"
        return 1
    fi
    rm -f "$validation_log"
}

wait_for_relay_ready() {
    local attempt
    for attempt in $(seq 1 50); do
        if curl -fsS --connect-timeout 1 --max-time 2 \
            "http://127.0.0.1:${ADMIN_PORT}/ready" 2>/dev/null | grep -qx 'LIVE'; then
            return 0
        fi
        systemctl is-failed --quiet apple-relay.service 2>/dev/null && return 1
        sleep 0.2
    done
    return 1
}

install_systemd_units() {
    {
        cat <<EOF
[Unit]
Description=Apple Network Relay (Envoy MASQUE)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=${ENVOY_BIN} -c ${ENVOY_CONFIG} --log-level info
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
    systemctl enable apple-relay.service >/dev/null
    systemctl enable --now apple-relay-renew.timer >/dev/null
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

    while true; do
        value="$(prompt_input "Listen IP address:" "${LISTEN_ADDRESS:-0.0.0.0}")"
        if is_valid_ip "$value"; then
            LISTEN_ADDRESS="$value"
            break
        fi
        log_warn "Enter a valid IPv4 address."
    done

    while true; do
        value="$(prompt_input "Relay TCP port:" "${LISTEN_PORT:-443}")"
        if is_valid_port "$value"; then
            LISTEN_PORT="$value"
            break
        fi
        log_warn "Enter a port between 1 and 65535."
    done

    while true; do
        CERT_EMAIL="$(prompt_input "Let's Encrypt account email:" "${CERT_EMAIL:-}")"
        [[ "$CERT_EMAIL" == *@*.* && "$CERT_EMAIL" != *$'\n'* && "$CERT_EMAIL" != *$'\r'* ]] && break
        log_warn "Enter a valid email address."
    done
}

install_relay() {
    require_root
    claim_project_dirs
    attach_tty
    require_tty
    install_base_dependencies
    install_gum
    publish_manager
    install_envoy

    local previous_listen_port=""
    local previous_admin_port=""
    if [[ -f "$ENV_FILE" ]]; then
        load_environment
        previous_listen_port="$LISTEN_PORT"
        previous_admin_port="$ADMIN_PORT"
    fi
    collect_install_configuration
    wait_for_dns
    preflight_ports "$previous_listen_port" "$previous_admin_port"
    save_environment

    if [[ ! -s "$TOKEN_FILE" ]]; then
        random_token | write_atomic "$TOKEN_FILE" 600
    fi
    issue_letsencrypt_certificate
    render_envoy_config
    secure_runtime_files
    validate_envoy_config
    install_systemd_units
    systemctl restart apple-relay.service
    wait_for_relay_ready \
        || { journalctl -u apple-relay.service -n 60 --no-pager >&2; die "Apple Relay failed to start."; }

    local token
    token="$(cat "$TOKEN_FILE")"
    {
        printf 'Apple Relay is ready.\n\n'
        printf 'HTTP/2 URL: https://%s:%s\n' "$DOMAIN" "$LISTEN_PORT"
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
    systemctl restart apple-relay.service
    wait_for_relay_ready || die "Apple Relay failed to restart."
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
    if ! systemctl restart apple-relay.service || ! wait_for_relay_ready; then
        printf '%s\n' "$old_token" | write_atomic "$TOKEN_FILE" 600
        render_envoy_config
        systemctl restart apple-relay.service || true
        wait_for_relay_ready || true
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
    dns_points_to_relay \
        || die "1.1.1.1 no longer returns only A=${PUBLIC_IPV4} for ${DOMAIN}; certificate renewal was not attempted."
    install_certbot
    local old_hash new_hash
    old_hash="$(sha256_file "${TLS_DIR}/fullchain.pem")"
    certbot renew --cert-name "$DOMAIN" --quiet
    copy_letsencrypt_lineage
    new_hash="$(sha256_file "${TLS_DIR}/fullchain.pem")"
    if [[ "$old_hash" != "$new_hash" ]]; then
        validate_envoy_config
        systemctl restart apple-relay.service
        wait_for_relay_ready || die "The certificate was renewed, but Apple Relay failed to become ready."
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
    dns_points_to_relay \
        || die "1.1.1.1 must return only A=${PUBLIC_IPV4} for ${DOMAIN} before certificate reissuance."
    issue_letsencrypt_certificate 1
    validate_envoy_config
    systemctl restart apple-relay.service
    wait_for_relay_ready || die "The new certificate was issued, but Apple Relay failed to become ready."
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
            "Install"|"Reconfigure / reinstall") install_relay ;;
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
