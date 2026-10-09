# Testing

Run `bash tests/run-unit.sh`. The suite checks shell syntax, ShellCheck, the checksum manifest, the Hysteria2 v2 payload, TLS pin generation, canonical URI generation and validation (including IPv6 and percent encoding), client add/read/list/link/enable/disable/remove behavior against a 3X-UI API mock, QR payload equality, UDP UFW ownership, root-only state, and backup manifest/archive permissions.

The schema and URI behavior were checked against official 3X-UI `v3.9.0`. `bash tests/integration/run.sh ubuntu:24.04` runs a privileged systemd container with `needrestart`, the real installer, 3X-UI and Xray. It decodes the generated QR, verifies that it exactly matches the exported URI, starts the official Hysteria v2.13.0 client with that URI, and sends HTTPS traffic through the tunnel before and after backup/restore. Set `HY2_INTEGRATION_TLS_MODE=trusted` to exercise a locally trusted certificate instead of the default pinned self-signed path. Setting `HY2_INTEGRATION_PENDING_KERNEL=1` simulates a newer installed kernel and verifies the non-blocking warning path.

Recorded final-audit evidence (2026-10-09):

| Target | Arch | Container build | Privileged systemd install | 3X-UI + Xray/inbound | Exact exported-client HTTPS |
|---|---|---:|---:|---:|---:|
| Ubuntu 18.04 | amd64 | Pass | Pass only with `--allow-unsupported-os` | Pass | Pass |
| Ubuntu 20.04 | amd64 | Pass | Pass | Pass | Pass |
| Ubuntu 22.04 | amd64 | Pass | Pass | Pass | Pass |
| Ubuntu 24.04 | amd64 | Pass | Pass | Pass | Pass, pinned and trusted TLS |
| Ubuntu 24.04 | arm64 (QEMU) | Pass | Pass | Pass | Pass, pinned TLS |
| Ubuntu 26.04 | amd64 | Pass | Pass | Pass | Pass, pinned TLS |

Ubuntu 18.04 remains unsupported by default despite the successful override test: it is EOL, below the project's security floor, and no longer a maintained production target. There was no current 3X-UI/Xray binary incompatibility in the disposable test. Ubuntu 20.04 is accepted but reported as best-effort because standard support has ended; use Ubuntu Pro/ESM. Ubuntu 22.04 and 26.04 were exercised on amd64, while their arm64 status is intended support based on the same architecture selection and published upstream assets, not a recorded lifecycle.

The focused manager regression additionally exercises status, info, clients, add/remove/enable/disable, QR/export, restart, logs with secret checks, diagnostics, repair without credential changes, backup/restore, pinned update/no-op self-update, and level-1 uninstall while an unrelated 3X-UI inbound survives.

A local listener is not an end-to-end test. These tests sent HTTPS through the official client tunnel and compared the tunnel's observed public exit with the host's direct public exit. Provider firewalls, NAT, QUIC filtering, DNS, renewal, and phone-client compatibility still need a real deployment smoke test.
