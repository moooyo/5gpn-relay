# 5GPN Apple Relay Manager

This repository has one job: install and operate an Apple Network Relay server through a Gum terminal interface.

It manages:

- an Envoy-based HTTP/2 MASQUE relay with CONNECT and CONNECT-UDP;
- `X-Relay-Token` authentication and safe token rotation;
- TLS certificate issuance, renewal, reissuance, and inspection;
- service status, logs, restart, reconfiguration, and uninstall;
- configuration-preserving, purging, and certificate-decommissioning uninstall modes.

## Requirements

- A root shell on a systemd-based Linux server.
- Debian/Ubuntu or a compatible RPM-based distribution.
- A relay hostname that clients can reach.
- A direct, DNS-only `A` record for that hostname.
- TCP on the selected relay port, normally `443`.
- TCP `80` for Let's Encrypt HTTP-01 issuance and renewal.

Gum and the official Envoy release binary are installed automatically. Both downloads use fixed versions and SHA-256 verification; no container runtime is required.

## Install

```bash
curl -fsSL https://moooyo.github.io/5gpn-relay/install.sh | sudo bash
```

After installation, open the management interface with:

```bash
sudo relayctl
```

## Certificates

The manager deliberately supports one certificate path: **Let's Encrypt HTTP-01**. During installation, it shows the exact `A` record to create and polls Cloudflare's `1.1.1.1` resolver until the public answer matches the selected server IPv4 address. Installation stops if the answer differs or an `AAAA` record is present. The public Internet must also be able to reach TCP port `80` on the selected listen address.

The manager installs a daily systemd renewal timer. Envoy is restarted only when the deployed certificate changes. A forced reissue is also available from the Gum interface.

## Client values

Use the values printed after installation in the Apple relay payload:

```xml
<key>HTTP2RelayURL</key>
<string>https://relay.example.com:443</string>
<key>AdditionalHTTPHeaderFields</key>
<dict>
  <key>X-Relay-Token</key>
  <string>the-token-shown-by-relayctl</string>
</dict>
```

The token is a credential. Rotating it immediately invalidates every profile that contains the previous token.

## Direct commands

```bash
sudo relayctl status
sudo relayctl restart
sudo relayctl rotate-token
sudo relayctl renew-cert
sudo relayctl reissue-cert
sudo relayctl logs
sudo relayctl uninstall keep
sudo relayctl uninstall purge
sudo relayctl uninstall decommission
```

`keep` preserves `/etc/apple-relay`. `purge` removes project configuration but leaves any Certbot lineage in place. `decommission` also asks Certbot to remove the relay hostname's lineage.

## Security model

- The generated token and Envoy configuration are root-only.
- Envoy runs as a dedicated unprivileged system user with a hardened systemd sandbox and only `CAP_NET_BIND_SERVICE`.
- The Envoy admin interface binds only to `127.0.0.1`.
- Configuration is validated with the pinned Envoy binary before service restart.
- Token rotation rolls back if validation or restart fails.
- The manager does not modify the host firewall.

Apple's relay payload requires HTTP/2 or HTTP/3 relay URLs and performs TLS server authentication. The default and recommended production path is a publicly trusted certificate.
