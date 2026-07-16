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
