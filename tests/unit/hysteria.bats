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
    link="hysteria2://secret-auth@203.0.113.7:443?security=tls&alpn=h3&sni=203.0.113.7&pinSHA256=$TLS_PIN#client1"
    run link_validate "$link" secret-auth; [ "$status" -eq 0 ]
    run link_validate "${link/443/8443}" secret-auth; [ "$status" -ne 0 ]; [[ "$output" == *"port"* ]]
    run link_validate "${link/secret-auth/wrong}" secret-auth; [ "$status" -ne 0 ]; [[ "$output" == *"auth"* ]]
}

@test "client add, read-back, link, disable, enable, list and remove work through API" {
    start_mock; api_configure; api_set_token "$MOCK_TOKEN"; API_TOKEN_SOURCE=env; seed_tls
    local body="$T/inbound.json"; inbound_build_json >"$body"; panel_inbound_add "$body"
    INBOUND_ID="$(api_obj .obj.id)" INBOUND_TAG="$(api_obj .obj.tag)" PANEL_BY_US=false; state_create
    client_create client1; panel_client_get client1
    [ "$(api_obj '.obj.client.auth|length')" -eq 32 ]
    run client_link client1; [ "$status" -eq 0 ]; [[ "$output" == hysteria2://* ]]
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
}

@test "state is root-only and stores no protocol branding in defaults" {
    seed_tls; INBOUND_ID=8 INBOUND_TAG=in-443-udp PANEL_BY_US=false; state_create
    [ "$(stat -c %a "$(state_file)")" = 600 ]
    [ "$(state_get .inbound.remark)" = Hysteria2 ]
    [ "$(state_get .inbound.transport)" = udp ]
}
