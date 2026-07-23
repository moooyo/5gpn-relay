#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT_DIR}/install.sh"

bash -n "$INSTALLER"

help_output="$(bash "$INSTALLER" help)"
grep -q 'Apple Relay manager' <<<"$help_output"
grep -q 'rotate-token' <<<"$help_output"
grep -q 'decommission' <<<"$help_output"
grep -q 'reissue-cert' <<<"$help_output"
grep -q 'https://1.1.1.1/dns-query' "$INSTALLER"
grep -q -- '--disable-hot-restart' "$INSTALLER"
grep -q 'spin --show-error' "$INSTALLER"
grep -q '^detect_previous_installation()' "$INSTALLER"
grep -q '^remove_previous_runtime_installation()' "$INSTALLER"
grep -q 'DropInPaths' "$INSTALLER"
grep -q -- '-verify_hostname' "$INSTALLER"
if grep -q -- '-checkhost' "$INSTALLER"; then
    echo "Certificate hostname checks must not depend on openssl x509 -checkhost exit codes." >&2
    exit 1
fi
grep -q 'ENVOY_SHA256_X86_64=' "$INSTALLER"
grep -q 'prompt_input "Relay domain:"' "$INSTALLER"
# shellcheck disable=SC2016
grep -Fq 'prompt_input "Public IPv4 for the DNS A record:" "${PUBLIC_IPV4:-$detected_public_ipv4}"' "$INSTALLER"

if grep -q 'prompt_input "Relay domain:" .*relay\.example\.com' "$INSTALLER"; then
    echo "The relay domain prompt must not have a default value." >&2
    exit 1
fi

if grep -qE 'prompt_input "(Listen IP address|Relay TCP port):"' "$INSTALLER"; then
    echo "The listen address and relay port must not be prompted." >&2
    exit 1
fi

grep -q 'LISTEN_ADDRESS="0.0.0.0"' "$INSTALLER"
grep -q 'LISTEN_PORT="443"' "$INSTALLER"
grep -q '"Install"|"Reconfigure / reinstall") install_relay; return 0 ;;' "$INSTALLER"
grep -q "printf 'Relay domain: %s" "$INSTALLER"

install_body="$(sed -n '/^install_relay() {$/,/^}$/p' "$INSTALLER")"
apply_body="$(sed -n '/^apply_install_configuration() {$/,/^}$/p' "$INSTALLER")"
gum_body="$(sed -n '/^install_gum() {$/,/^}$/p' "$INSTALLER")"
grep -q 'apply_install_configuration' <<<"$install_body"
grep -q 'ensure_letsencrypt_certificate' <<<"$apply_body"
if grep -q 'command_exists gum' <<<"$gum_body"; then
    echo "Installation must use the pinned Gum download instead of a system Gum binary." >&2
    exit 1
fi
if grep -qE '^[[:space:]]+issue_letsencrypt_certificate([[:space:]]|$)' <<<"${install_body}${apply_body}"; then
    echo "Installation must validate and reuse a current certificate before requesting one." >&2
    exit 1
fi

if grep -q "printf 'HTTP/2 URL:" "$INSTALLER"; then
    echo "The installation result must display only the relay domain." >&2
    exit 1
fi

stdin_help_output="$(bash -s -- help <"$INSTALLER")"
grep -q 'Apple Relay manager' <<<"$stdin_help_output"

if grep -nE 'dns-cloudflare|self-signed|HTTP3RelayURL|relay_http3' "$INSTALLER"; then
    echo "Only HTTP-01 certificates and the HTTP/2 relay are supported." >&2
    exit 1
fi

if grep -nE '/dev/shm/envoy_shared_memory|[[:space:]]pkill[[:space:]].*envoy' "$INSTALLER"; then
    echo "The installer must not delete global Envoy IPC or kill unrelated Envoy processes." >&2
    exit 1
fi

if grep -nE '[[:space:]](curl|wget)[[:space:]].*\|[[:space:]]*(ba)?sh' "$INSTALLER"; then
    echo "Remote shell pipelines are not allowed in the installer." >&2
    exit 1
fi

if grep -nE 'chmod[[:space:]]+777|--privileged|network[=:][[:space:]]*host.*--privileged' "$INSTALLER"; then
    echo "An unsafe container or file permission was found." >&2
    exit 1
fi

echo "Static checks passed."
