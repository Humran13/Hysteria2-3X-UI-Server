#!/usr/bin/env bash
# Exercise the exact production URI with the official Hysteria client.
set -Eeuo pipefail

HYSTERIA_VERSION=2.13.0
case "$(uname -m)" in
    x86_64) asset=hysteria-linux-amd64; expected=907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691 ;;
    aarch64 | arm64) asset=hysteria-linux-arm64; expected=a68a61a84452ca250ce0368202521965ca9cc9d801a404f1dc9008ac6cf677a7 ;;
    *) echo "unsupported Hysteria integration architecture: $(uname -m)" >&2; exit 1 ;;
esac

binary=/tmp/hysteria-official
if [[ ! -x "$binary" ]]; then
    curl -fL --retry 3 --connect-timeout 15 --max-time 180 \
        "https://github.com/apernet/hysteria/releases/download/app%2Fv${HYSTERIA_VERSION}/${asset}" -o "$binary"
    printf '%s  %s\n' "$expected" "$binary" | sha256sum -c -
    chmod 755 "$binary"
fi

uri="$(hysteria2 export client1 --format uri)"
[[ "$uri" == hysteria2://*/*\?* ]]
info="$(hysteria2 info client1)"
grep -Fqx "  $uri" <<<"$info"

# The manager's QR command passes this same client_link payload to qrencode.
# Decode a PNG encoding of that payload as a second, independent equality check.
qrencode -o /tmp/hy2-client.png "$uri"
decoded="$(zbarimg --quiet --raw /tmp/hy2-client.png)"
[[ "$decoded" == "$uri" ]]

cat >/tmp/hysteria-client.yaml <<EOF
server: "$uri"
http:
  listen: 127.0.0.1:18082
EOF

rm -f /tmp/hysteria-client.log
"$binary" client -c /tmp/hysteria-client.yaml >/tmp/hysteria-client.log 2>&1 &
client_pid=$!
cleanup() { kill "$client_pid" 2>/dev/null || true; }
trap cleanup EXIT
for _ in $(seq 1 100); do
    if ! kill -0 "$client_pid" 2>/dev/null; then
        cat /tmp/hysteria-client.log >&2
        exit 1
    fi
    ss -ltn 'sport = :18082' | grep -q 18082 && break
    sleep 0.2
done
ss -ltn 'sport = :18082' | grep -q 18082
grep -q 'connected to server' /tmp/hysteria-client.log

curl --fail --silent --show-error --retry 2 --max-time 30 \
    -x http://127.0.0.1:18082 https://example.com/ -o /tmp/hy2-exact-https.html
grep -qi '<title>Example Domain</title>' /tmp/hy2-exact-https.html
direct_ip="$(curl --fail --silent --show-error --retry 2 --max-time 30 https://api.ipify.org)"
tunnel_ip="$(curl --fail --silent --show-error --retry 2 --max-time 30 \
    -x http://127.0.0.1:18082 https://api.ipify.org)"
[[ -n "$direct_ip" && "$tunnel_ip" == "$direct_ip" ]]

cleanup
trap - EXIT
printf 'OFFICIAL_EXACT_URI_E2E_OK tls=%s exit_ip_match=yes\n' "$(jq -r .tls.mode /etc/hysteria2-3x-ui-server/state.json)"
