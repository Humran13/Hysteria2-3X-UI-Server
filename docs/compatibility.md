# Compatibility audit

This matrix is deliberately narrower than a list of applications that advertise Hysteria2. “Format” means the exact canonical URI shape is documented or source-checked; “parser” means the current parser was inspected or executed with representative production URIs; “network” means this project's exact exported profile carried traffic in that client.

| Client | Format verified | Parser verified | Network verified | Notes |
|---|---:|---:|---:|---|
| Official Hysteria 2.13.0 | Yes | Yes | Yes | The unmodified `hysteria2 export client1 --format uri` value was used as `server`; QR decoded to the same bytes; HTTPS passed through the tunnel for pinned and trusted TLS. |
| Hiddify app 4.0.4 | Yes | Yes | No | Tested its pinned `ray2sing` parser with IPv4/pinned and IPv6/encoded canonical URIs. Scheme, slash/query, auth, host/port, SNI, `insecure=1`, and remark map correctly. Current parser accepts but discards `pinSHA256`, so self-signed Hiddify use relies on insecure TLS rather than pin enforcement. No Android connection was run. |
| HTTP Injector | No | No | No | No current authoritative parser evidence or exact-profile test was available. |
| HTTP Custom | No | No | No | Its official API documentation lists `hysteria2://`/`hy2://`, but that does not prove its Android importer preserves this exact URI's pin and fields. |
| sing-box | No | No | No | The core accepts structured JSON Hysteria2 outbounds; direct canonical-URI import is a responsibility of a front-end/converter such as Hiddify's parser. |
| Mihomo/Clash | No | No | No | Mihomo documents structured YAML Hysteria2 proxies. No direct-core test of this exact URI or network connection was performed. |

## Hiddify source check

The audit used Hiddify app v4.0.4 commit `956177a3cd0e9613f3a4e3b336fcc626bc29f19a`, its pinned hiddify-core commit `a909abda8271fa48c92447a6d224ee7a0087f0d2`, and pinned ray2sing commit `eb11472dfc6ac5e92dfba5214022378049361192`. The parser test ran under its declared Go 1.25.6 toolchain and passed both representative cases. Hiddify's own fixture uses the canonical slash-before-query form and the same `insecure`, `pinSHA256`, obfuscation, and SNI parameter spelling.

The project does not export an `alpn` query parameter. The official Hysteria client successfully negotiates the Hysteria2 connection from this URI, and Hiddify's Hysteria2 URI parser does not map an ALPN query parameter. The Xray inbound itself is configured with ALPN `h3`.

Primary references: [Hysteria2 URI scheme](https://v2.hysteria.network/docs/developers/URI-Scheme/), [Hiddify URL scheme](https://github.com/hiddify/hiddify-app/wiki/URL-Scheme), [Hiddify app releases](https://github.com/hiddify/hiddify-app/releases), [HTTP Custom API](https://eprodev.org/api/), [sing-box Hysteria2 options](https://github.com/SagerNet/sing-box/blob/testing/option/hysteria2.go), and [Mihomo Hysteria2 configuration](https://github.com/MetaCubeX/Meta-Docs/blob/main/docs/config/proxies/hysteria2.en.md).
