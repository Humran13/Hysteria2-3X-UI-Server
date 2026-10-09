#!/usr/bin/env bash
# Real 3X-UI/Xray lifecycle. Run only inside the privileged systemd test container.
set -Eeuo pipefail
SRC="${1:-/src}"
WORK=/tmp/hy2-source
rm -rf "$WORK"
cp -a "$SRC" "$WORK"
chmod +x "$WORK/install.sh" "$WORK/bin/hysteria2" "$WORK/tools/"*.sh

install_args=(--panel-version v3.9.0 --server-address 127.0.0.1 --non-interactive)
if [[ "${HY2_INTEGRATION_ALLOW_UNSUPPORTED:-0}" == "1" ]]; then
    install_args+=(--allow-unsupported-os)
fi
if [[ "${HY2_INTEGRATION_TLS_MODE:-self-signed}" == "trusted" ]]; then
    install -d -m 700 /etc/hysteria2-integration
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=HY2-Integration-CA \
        -keyout /etc/hysteria2-integration/ca.key -out /usr/local/share/ca-certificates/hy2-integration-ca.crt >/dev/null 2>&1
    openssl req -newkey rsa:2048 -nodes -subj /CN=hy2.test \
        -keyout /etc/hysteria2-integration/server.key -out /tmp/hy2-server.csr >/dev/null 2>&1
    printf 'subjectAltName=DNS:hy2.test\nextendedKeyUsage=serverAuth\n' >/tmp/hy2-server.ext
    openssl x509 -req -days 2 -sha256 -in /tmp/hy2-server.csr \
        -CA /usr/local/share/ca-certificates/hy2-integration-ca.crt -CAkey /etc/hysteria2-integration/ca.key -CAcreateserial \
        -extfile /tmp/hy2-server.ext -out /etc/hysteria2-integration/server.crt >/dev/null 2>&1
    chmod 600 /etc/hysteria2-integration/server.key
    update-ca-certificates >/dev/null
    install_args+=(--sni hy2.test --tls-cert /etc/hysteria2-integration/server.crt --tls-key /etc/hysteria2-integration/server.key)
fi

if [[ "${HY2_INTEGRATION_PENDING_KERNEL:-0}" == "1" ]]; then
    mkdir -p /boot
    touch "/boot/vmlinuz-$(uname -r)" /boot/vmlinuz-99.99.0-integration-test
    "$WORK/install.sh" "${install_args[@]}" 2>&1 | tee /tmp/hy2-install.log
    grep -q 'newer kernel is installed' /tmp/hy2-install.log
    grep -q 'Continuing unattended; no keyboard input will be required' /tmp/hy2-install.log
    if grep -q "awk: option .*interactive.*unrecognized" /tmp/hy2-install.log; then
        echo 'unsupported awk interactive warning was emitted' >&2
        exit 1
    fi
else
    "$WORK/install.sh" "${install_args[@]}"
fi
hysteria2 status
hysteria2 diagnostics
bash "$WORK/tests/integration/exact-client.sh"

hysteria2 add-client Alice --quota-gb 1 --expire-days 1 >/tmp/alice.txt
grep -q 'hysteria2://' /tmp/alice.txt
hysteria2 disable-client Alice
hysteria2 enable-client Alice
hysteria2 restart
state_file=/etc/hysteria2-3x-ui-server/state.json
auth_before="$(jq -r '.clients | sort_by(.email) | .[].auth' "$state_file" | sha256sum | awk '{print $1}')"
cert_path="$(jq -r '.tls.cert' "$state_file")"
key_path="$(jq -r '.tls.key' "$state_file")"
cert_before="$(sha256sum "$cert_path" | awk '{print $1}')"
key_before="$(sha256sum "$key_path" | awk '{print $1}')"
backup="$(hysteria2 backup 2>&1 | sed -n 's/^.*Backup written: //p')"
[[ -f "$backup" ]]
[[ "$(stat -c %a "$backup")" == 600 ]]
tar -xOf "$backup" ./manifest.json | jq -e '.format == 2 and .kind == "manual" and .protocol == "hysteria2"' >/dev/null
uri_before="$(hysteria2 export client1 --format uri)"
hysteria2 add-client Bob >/dev/null
hysteria2 --yes restore "$backup"
sleep 3
clients="$(hysteria2 clients)"
grep -q Alice <<<"$clients"
if grep -q Bob <<<"$clients"; then echo 'Bob survived restore unexpectedly' >&2; exit 1; fi
[[ "$(hysteria2 export client1 --format uri)" == "$uri_before" ]]
[[ "$(jq -r '.clients | sort_by(.email) | .[].auth' "$state_file" | sha256sum | awk '{print $1}')" == "$auth_before" ]]
[[ "$(sha256sum "$cert_path" | awk '{print $1}')" == "$cert_before" ]]
[[ "$(sha256sum "$key_path" | awk '{print $1}')" == "$key_before" ]]
bash "$WORK/tests/integration/exact-client.sh"

echo 'REAL_LIFECYCLE_OK'
