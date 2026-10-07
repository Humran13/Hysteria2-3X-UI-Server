# Architecture

`install.sh` verifies the checksum manifest and atomically installs the runtime under `/opt/hysteria2-3x-ui-server`. `bin/hysteria2` loads `lib/` modules and uses 3X-UI's documented Bearer-token API; it never edits the panel database directly.

The inbound uses protocol `hysteria`, inbound and transport version `2`, Hysteria transport, TLS, ALPN `h3`, and UDP. Clients are separate 3X-UI v3 records with random `auth` credentials. After create/update, the code fetches the authoritative record and validates protocol, versions, transport, TLS paths, client auth, core state, UDP socket, and share URI.

Runtime state is root-only in `/etc/hysteria2-3x-ui-server`; backups are in `/var/backups/hysteria2-3x-ui-server`; redacted logs are in `/var/log/hysteria2-3x-ui-server/hysteria2.log`.

The default certificate is self-signed and pinned in the URI. Supplying a trusted certificate/key removes the pin. UFW management adds/removes only the recorded UDP rule and never changes global policy.
