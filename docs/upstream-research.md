# Upstream research

Validated against official 3X-UI tag `v3.9.0`.

- Hysteria2 is inbound protocol `hysteria`; Xray accepts version `2`.
- The stream is `network: hysteria` with `hysteriaSettings.version: 2` and a 2–600 second UDP idle timeout.
- Hysteria is QUIC/TLS, uses ALPN `h3`, and requires a server certificate.
- Each client uses `auth` as its connection credential.
- `/panel/api/clients/links/{email}` emits `hysteria2://` links, but in v3.9.0 its self-signed form omits the `insecure=1` flag required by the official Hysteria client and includes panel-specific query keys. The wrapper therefore builds and validates the canonical URI from the API client credential and its saved inbound/TLS state.
- The wrapper's URI was exercised unchanged through QR encode/decode and the official Hysteria v2.13.0 client with both pinned self-signed and locally trusted certificate chains.
- Creation is verified by reading both client and inbound back from their API endpoints.

## Capability boundary

The 3X-UI v3.9.0 / Xray 26.9.30 source was audited before deciding what this wrapper should expose.

| Mode | Upstream capability | This project |
|---|---|---|
| Normal Hysteria2 UDP/QUIC | Yes | Supported and exact-client tested |
| Trusted TLS | Yes | Supported and exact-client tested |
| Pinned self-signed TLS | Yes | Supported and exact-client tested |
| Single UDP port | Yes | Supported and firewall-tested |
| Salamander | Yes | Not exposed; no project client matrix/test |
| Gecko | Yes | Not exposed; uneven support across common clients |
| Port hopping | Client-side `udphop`/multi-port support; a server still needs an external UDP range forwarded to its listening port | Not implemented; no range firewall/NAT ownership model |
| Masquerade proxy/file/string | Present in current upstream Hysteria2 implementations | Not exposed or validated through this project's Xray/3X-UI path |
| Congestion/QUIC tuning | Upstream fields exist | Not exposed; upstream defaults are retained |

The wrapper therefore does not manufacture URI parameters or installer switches for modes it cannot validate end to end.

Primary references: [3X-UI](https://github.com/MHSanaei/3x-ui), [inbound API](https://github.com/MHSanaei/3x-ui/blob/v3.9.0/docs/content/docs/en/reference/api/inbounds.mdx), [transports](https://github.com/MHSanaei/3x-ui/blob/v3.9.0/docs/content/docs/en/config/transports.mdx), [Xray-core](https://github.com/XTLS/Xray-core/tree/v26.9.30), [Hysteria2 URI scheme](https://v2.hysteria.network/docs/developers/URI-Scheme/).
