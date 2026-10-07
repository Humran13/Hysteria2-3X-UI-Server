# Testing

Run `bash tests/run-unit.sh`. The suite checks shell syntax, the Hysteria2 v2 payload, TLS pin generation, URI validation, client add/read/list/link/enable/disable/remove behavior against a 3X-UI API mock, UDP UFW ownership, and root-only state.

The schema and URI behavior were checked against official 3X-UI `v3.9.0`. `bash tests/integration/run.sh ubuntu:24.04` runs a privileged systemd container with the real installer, 3X-UI and Xray, including traffic through a generated Hysteria2 client.

| Target | Architecture | Status |
|---|---|---|
| Local development container | amd64 | Unit/static suite |
| Ubuntu 20.04 | amd64/arm64 | Supported target; live Hysteria2 lifecycle not yet recorded |
| Ubuntu 22.04 | amd64/arm64 | Supported target; live Hysteria2 lifecycle not yet recorded |
| Ubuntu 24.04 | amd64 | Real 3X-UI v3.9.0 / Xray 26.9.30 lifecycle and HTTP traffic passed |
| Ubuntu 24.04 | arm64 | Supported target; not tested in this run |
| Ubuntu 26.04 | amd64/arm64 | Best effort until upstream/runtime availability is confirmed on a released image |

A local listener is not an end-to-end test. Provider firewalls, NAT, QUIC filtering, DNS, renewal, and phone-client compatibility need an external smoke test.
