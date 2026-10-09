# Hysteria2 + 3X-UI Server

An idempotent Ubuntu installer for a 3X-UI-managed Hysteria2 server. It installs official stable 3X-UI, creates one enabled Hysteria2 v2 inbound on UDP, creates `client1`, validates the saved configuration, waits for Xray and the UDP listener, and prints a `hysteria2://` URI and terminal QR code.

## Install

Run as root on a fresh Ubuntu VPS:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Humran13/Hysteria2-3X-UI-Server/main/install.sh)
```

Defaults: UDP `443`, remark `Hysteria2`, client `client1`, and a securely generated 32-character client auth value. If UDP 443 is occupied, an interactive install asks for another port; a non-interactive install exits and asks you to pass `--port`.

Supported targets are Ubuntu 20.04, 22.04, 24.04, and 26.04 on amd64 or arm64 where the current 3X-UI release publishes a matching binary. See [testing notes](docs/testing.md) for what was actually exercised; this is not a claim that every provider/kernel combination was tested.

The installer deliberately exposes one well-tested mode: normal single-port Hysteria2 over UDP/QUIC, with either pinned self-signed TLS or an administrator-supplied trusted certificate. Salamander, Gecko, port hopping, masquerade content, and manual congestion/QUIC tuning are not installer options in this release. Upstream support alone is not treated as validated project support; see the [capability and client matrix](docs/compatibility.md).

## What it configures

- Official stable [3X-UI](https://github.com/MHSanaei/3x-ui), currently validated against `v3.9.0`.
- Xray-native Hysteria2: panel protocol `hysteria`, settings version `2`, Hysteria transport version `2`, UDP/QUIC, TLS, ALPN `h3`.
- A custom share address for the public endpoint. The wrapper generates a canonical Hysteria2 URI instead of relying on the panel's version-specific share-link output.
- One neutral client whose auth credential is generated with the OS CSPRNG.
- One `port/udp` UFW rule only when UFW is already active. The installer never enables, resets, or flushes a firewall and never opens the panel port.

The zero-domain default creates a self-signed certificate and puts both `insecure=1` and its SHA-256 pin in the generated URI. The pin still authenticates the expected certificate while `insecure=1` allows the official Hysteria client to accept that self-signed chain. The client must support the standard Hysteria2 `pinSHA256` URI parameter.

For production with a trusted certificate:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Humran13/Hysteria2-3X-UI-Server/main/install.sh) -- \
  --server-address vpn.example.com --sni vpn.example.com \
  --tls-cert /etc/letsencrypt/live/vpn.example.com/fullchain.pem \
  --tls-key /etc/letsencrypt/live/vpn.example.com/privkey.pem
```

The project validates those files and records their resolved paths without taking ownership. Certificate issuance and renewal remain the administrator's responsibility; run `sudo hysteria2 restart` after renewal.

## Management

```text
sudo hysteria2 status
sudo hysteria2 info [NAME]
sudo hysteria2 clients
sudo hysteria2 add-client [NAME] [--expire-days N] [--quota-gb N]
sudo hysteria2 qr [NAME]
sudo hysteria2 export [NAME] --format uri
sudo hysteria2 disable-client NAME
sudo hysteria2 enable-client NAME
sudo hysteria2 remove-client NAME
sudo hysteria2 logs
sudo hysteria2 restart
sudo hysteria2 diagnostics
sudo hysteria2 repair
sudo hysteria2 backup
sudo hysteria2 restore FILE
sudo hysteria2 update
sudo hysteria2 update --self
sudo hysteria2 uninstall --level 1|2|3
```

Level 1 removes only managed resources. Level 2 also removes this wrapper. Level 3 invokes the official 3X-UI uninstaller and deletes all panel data after typed confirmation. Backups are retained.

## Firewall and troubleshooting

Allow the chosen port as **UDP**, not just TCP, in the VPS provider firewall/security group. Preserve SSH access. Then run:

```bash
sudo hysteria2 diagnostics
sudo systemctl status x-ui
sudo journalctl -u x-ui -n 100 --no-pager
sudo ss -lunp | grep ':443'
```

If a client cannot import the link, confirm it supports Hysteria2 and certificate pinning. Some clients implement only a subset of the URI standard; a trusted certificate gives the broadest compatibility. QUIC may also be blocked by the client network.

API tokens, client auth values, certificate keys, state, and backups are root-only. Secrets are passed in request-body files and logs are redacted. Unrelated panel resources are preserved by repair and normal uninstall levels.

Blue Soft Keys branding is limited to project attribution and the banner. Generated profiles remain generic. License: MIT for this wrapper; dependencies retain their licenses (see [NOTICE.md](NOTICE.md)).
