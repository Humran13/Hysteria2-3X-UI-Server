#!/usr/bin/env bats
load helpers.bash

setup() { hy2_test_env; load_libs; }
teardown() { stop_mock; }

seed_tls() {
    SERVER_ADDR=203.0.113.7 PORT=443 TLS_MODE=self-signed-pinned
    TLS_CERT="$T/server.crt" TLS_KEY="$T/server.key" TLS_SNI=203.0.113.7
    openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj /CN=203.0.113.7 -keyout "$TLS_KEY" -out "$TLS_CERT" >/dev/null 2>&1
    TLS_PIN="$(hysteria_cert_pin "$TLS_CERT")"
}

@test "inbound generator emits native Hysteria2 v2 over UDP/QUIC TLS" {
    seed_tls; run inbound_build_json; [ "$status" -eq 0 ]
    [ "$(jq -r .protocol <<<"$output")" = hysteria ]
    [ "$(jq -r .settings.version <<<"$output")" = 2 ]
    [ "$(jq -r .streamSettings.network <<<"$output")" = hysteria ]
    [ "$(jq -r .streamSettings.hysteriaSettings.version <<<"$output")" = 2 ]
    [ "$(jq -r .streamSettings.security <<<"$output")" = tls ]
    [ "$(jq -r .streamSettings.tlsSettings.alpn[0] <<<"$output")" = h3 ]
    [ "$(jq -r .remark <<<"$output")" = Hysteria2 ]
}

@test "pinned Hysteria2 URI parses and validates" {
    seed_tls
    link="hysteria2://secret-auth@203.0.113.7:443/?sni=203.0.113.7&insecure=1&pinSHA256=$TLS_PIN#client1"
    run link_validate "$link" secret-auth; [ "$status" -eq 0 ]
    run link_validate "${link/443/8443}" secret-auth; [ "$status" -ne 0 ]; [[ "$output" == *"port"* ]]
    run link_validate "${link/secret-auth/wrong}" secret-auth; [ "$status" -ne 0 ]; [[ "$output" == *"auth"* ]]
    run link_validate "${link/&insecure=1/}" secret-auth; [ "$status" -ne 0 ]; [[ "$output" == *"insecure=1"* ]]
}

@test "canonical URI percent-encodes credentials and remarks and brackets IPv6" {
    seed_tls
    SERVER_ADDR=2001:db8::7 TLS_SNI=2001:db8::7
    link="$(client_uri_build 'a:b@c /+' 'Alice Smith')"
    [[ "$link" == 'hysteria2://a%3Ab%40c%20%2F%2B@[2001:db8::7]:443/?'* ]]
    [[ "$link" == *'sni=2001%3Adb8%3A%3A7&insecure=1&pinSHA256='* ]]
    [[ "$link" == *'#Hysteria2-Alice%20Smith' ]]
    link_parse "$link"
    [ "$LINK_AUTH" = 'a:b@c /+' ]
    [ "$LINK_HOST" = '2001:db8::7' ]
    [ "$LINK_NAME" = 'Hysteria2-Alice Smith' ]
}

@test "IPv6 validation is independent of host network configuration" {
    valid_ipv6 '2001:db8::7'
    valid_ipv6 '::1'
    valid_ipv6 '2001:db8:0:1:2:3:4:5'
    ! valid_ipv6 '2001:db8::1::2'
    ! valid_ipv6 '2001:db8:0:1:2:3:4'
    ! valid_ipv6 '2001:db8:0:1:2:3:4:12345'
    ! valid_ipv6 '2001:db8:::7'
}

@test "trusted TLS export omits insecure and pin parameters" {
    SERVER_ADDR=vpn.example.com PORT=443 TLS_MODE=provided TLS_SNI=vpn.example.com TLS_PIN=
    link="$(client_uri_build secret client1)"
    [[ "$link" == 'hysteria2://secret@vpn.example.com:443/?sni=vpn.example.com#Hysteria2-client1' ]]
    run link_validate "$link" secret; [ "$status" -eq 0 ]
    run link_validate "${link/\?sni=/\?insecure=1\&sni=}" secret
    [ "$status" -ne 0 ]; [[ "$output" == *"trusted TLS"* ]]
}

@test "client add, read-back, link, disable, enable, list and remove work through API" {
    start_mock; api_configure; api_set_token "$MOCK_TOKEN"; API_TOKEN_SOURCE=env; seed_tls
    local body="$T/inbound.json"; inbound_build_json >"$body"; panel_inbound_add "$body"
    INBOUND_ID="$(api_obj .obj.id)" INBOUND_TAG="$(api_obj .obj.tag)" PANEL_BY_US=false; state_create
    client_create client1; panel_client_get client1
    [ "$(api_obj '.obj.client.auth|length')" -eq 32 ]
    run client_link client1; [ "$status" -eq 0 ]; [[ "$output" == hysteria2://* ]]
    link="$output"
    cat >"$T/shims/qrencode" <<'EOS'
#!/bin/bash
printf '%s' "${@: -1}" >"$MOCK_DIR/qr-payload"
EOS
    chmod +x "$T/shims/qrencode"
    client_qr client1
    [ "$(cat "$MOCK_DIR/qr-payload")" = "$link" ]
    client_set_enabled client1 false; [ "$(api_obj .obj.client.enable)" = false ]
    client_set_enabled client1 true; run client_list; [[ "$output" == *client1* ]]
    client_remove client1; run panel_client_get client1; [ "$status" -ne 0 ]
}

@test "UFW rule is UDP, idempotent, and only an owned rule is removed" {
    seed_tls; INBOUND_ID=1 INBOUND_TAG=in-443-udp PANEL_BY_US=false; state_create; touch "$MOCK_DIR/ufw_active"
    fw_open_port 443; fw_open_port 443
    [ "$(grep -c '^443/udp$' "$MOCK_DIR/ufw_rules")" -eq 1 ]
    [ "$(state_get '.firewall.ufw_rules[0]')" = 443/udp ]
    fw_close_ours; ! grep -q '^443/udp$' "$MOCK_DIR/ufw_rules"

    # A pre-existing rule, including an SSH rule, is never claimed or removed.
    printf '8443/udp\n22/tcp\n' >"$MOCK_DIR/ufw_rules"
    fw_open_port 8443
    [ "$(state_get '.firewall.ufw_rules | length')" -eq 0 ]
    fw_close_ours
    grep -qx '8443/udp' "$MOCK_DIR/ufw_rules"
    grep -qx '22/tcp' "$MOCK_DIR/ufw_rules"
}

@test "state is root-only and stores no protocol branding in defaults" {
    seed_tls; INBOUND_ID=8 INBOUND_TAG=in-443-udp PANEL_BY_US=false; state_create
    [ "$(stat -c %a "$(state_file)")" = 600 ]
    [ "$(state_get .inbound.remark)" = Hysteria2 ]
    [ "$(state_get .inbound.transport)" = udp ]
}

@test "backup archive has a valid manifest and root-only permissions" {
    start_mock; api_configure; api_set_token "$MOCK_TOKEN"
    seed_tls; INBOUND_ID=8 INBOUND_TAG=in-443-udp PANEL_BY_US=false; state_create
    upstream_version() { echo v3.9.0; }
    upstream_xray_version() { echo 26.9.30; }
    archive="$(backup_create unit)"
    [ -f "$archive" ]
    [ "$(stat -c %a "$HY2_BACKUP_DIR")" = 700 ]
    [ "$(stat -c %a "$archive")" = 600 ]
    run tar -xOf "$archive" ./manifest.json
    [ "$status" -eq 0 ]
    [ "$(jq -r '.format' <<<"$output")" = 2 ]
    [ "$(jq -r '.kind' <<<"$output")" = unit ]
    [ "$(jq -r '.panel_version' <<<"$output")" = v3.9.0 ]
}
