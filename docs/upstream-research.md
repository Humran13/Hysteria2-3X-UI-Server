# Upstream research

Validated against official 3X-UI tag `v3.9.0`.

- Hysteria2 is inbound protocol `hysteria`; Xray accepts version `2`.
- The stream is `network: hysteria` with `hysteriaSettings.version: 2` and a 2–600 second UDP idle timeout.
- Hysteria is QUIC/TLS, uses ALPN `h3`, and requires a server certificate.
- Each client uses `auth` as its connection credential.
- `/panel/api/clients/links/{email}` emits `hysteria2://` links and hexadecimal `pinSHA256` values.
- Creation is verified by reading both client and inbound back from their API endpoints.

Primary references: [3X-UI](https://github.com/MHSanaei/3x-ui), [inbound API](https://github.com/MHSanaei/3x-ui/blob/v3.9.0/docs/content/docs/en/reference/api/inbounds.mdx), [transports](https://github.com/MHSanaei/3x-ui/blob/v3.9.0/docs/content/docs/en/config/transports.mdx), [Hysteria2 URI scheme](https://v2.hysteria.network/docs/developers/URI-Scheme/).
