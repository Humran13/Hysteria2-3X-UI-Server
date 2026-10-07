#!/usr/bin/env bash
# Real 3X-UI/Xray lifecycle. Run only inside the privileged systemd test container.
set -Eeuo pipefail
SRC="${1:-/src}"
WORK=/tmp/hy2-source
cp -a "$SRC" "$WORK"
chmod +x "$WORK/install.sh" "$WORK/bin/hysteria2" "$WORK/tools/"*.sh

"$WORK/install.sh" --panel-version v3.9.0 --server-address 127.0.0.1 --non-interactive
hysteria2 status
hysteria2 diagnostics

STATE=/etc/hysteria2-3x-ui-server/state.json
auth="$(jq -r '.clients[0].auth' "$STATE")"
pin="$(jq -r '.tls.pin_sha256' "$STATE")"
xray="$(find /usr/local/x-ui/bin -maxdepth 1 -type f -name 'xray-linux-*' | head -n1)"

jq -n --arg auth "$auth" --arg pin "$pin" '{
  log:{loglevel:"warning"},
  inbounds:[{listen:"127.0.0.1",port:18081,protocol:"http",settings:{}}],
  outbounds:[{protocol:"hysteria",settings:{version:2,address:"127.0.0.1",port:443},streamSettings:{
    network:"hysteria",security:"tls",
    tlsSettings:{serverName:"127.0.0.1",alpn:["h3"],pinnedPeerCertSha256:$pin},
    hysteriaSettings:{version:2,auth:$auth}
  }}]
}' >/tmp/hy2-client.json
"$xray" run -test -c /tmp/hy2-client.json
"$xray" run -c /tmp/hy2-client.json >/tmp/hy2-client.log 2>&1 &
client_pid=$!
trap 'kill "$client_pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do ss -ltn 'sport = :18081' | grep -q 18081 && break; sleep .2; done
code="$(curl -sS -o /tmp/hy2-traffic.html -w '%{http_code}' -x http://127.0.0.1:18081 --max-time 20 http://example.com/)"
[[ "$code" == 200 ]] && grep -qi example /tmp/hy2-traffic.html
kill "$client_pid" 2>/dev/null || true
trap - EXIT

hysteria2 add-client Alice --quota-gb 1 --expire-days 1 >/tmp/alice.txt
grep -q 'hysteria2://' /tmp/alice.txt
hysteria2 disable-client Alice
hysteria2 enable-client Alice
hysteria2 restart
backup="$(hysteria2 backup 2>&1 | sed -n 's/^.*Backup written: //p')"
[[ -f "$backup" ]]
hysteria2 add-client Bob >/dev/null
hysteria2 --yes restore "$backup"
sleep 3
clients="$(hysteria2 clients)"
grep -q Alice <<<"$clients"
if grep -q Bob <<<"$clients"; then echo 'Bob survived restore unexpectedly' >&2; exit 1; fi

echo 'REAL_LIFECYCLE_OK'
