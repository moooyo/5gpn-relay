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

stdin_help_output="$(bash -s -- help <"$INSTALLER")"
grep -q 'Apple Relay manager' <<<"$stdin_help_output"

if grep -nE 'dns-cloudflare|self-signed|HTTP3RelayURL|relay_http3' "$INSTALLER"; then
    echo "Only HTTP-01 certificates and the HTTP/2 relay are supported." >&2
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
