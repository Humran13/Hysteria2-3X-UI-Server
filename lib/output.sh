#!/usr/bin/env bash
# shellcheck shell=bash
_kv() { printf '  %-22s %s\n' "$1" "$2"; }
output_banner() { printf '%s\n %s\n%s\n' '==========================================================' "$HY2_PRODUCT" '==========================================================' >&2; }
output_connection_details() {
    printf '\nConnection details\n'; _kv Protocol Hysteria2; _kv Transport 'UDP / QUIC'; _kv 'Server address' "$SERVER_ADDR"; _kv 'UDP port' "$PORT"; _kv 'TLS server name' "$TLS_SNI"
    if [[ "$TLS_MODE" == self-signed-pinned ]]; then _kv TLS 'Pinned self-signed certificate'; _kv 'SHA-256 pin' "$TLS_PIN"; else _kv TLS 'User-provided certificate'; fi
}
output_client_block() { local name="$1" link; link="$(client_link "$name")" || true; printf '\nClient: %s\n' "$name"; if [[ -n "$link" ]]; then printf '  %s\n' "$link"; printf '  QR: sudo hysteria2 qr %s\n' "$name"; else printf '  (link unavailable; run diagnostics)\n'; fi; }
output_panel_hint() {
    upstream_panel_settings 2>/dev/null || return 0
    local base="${PANEL_BASE_PATH:+/$PANEL_BASE_PATH/}"
    printf '\n3X-UI panel\n'; _kv 'Local URL' "http://127.0.0.1:${PANEL_PORT}${base:-/}"; _kv Credentials "sudo cat $UPSTREAM_RESULT_FILE"; _kv 'SSH tunnel' "ssh -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} root@${SERVER_ADDR}"
    printf '  The panel port is not opened by this project.\n'
}
output_info() {
    state_require; output_connection_details
    if (($#)); then output_client_block "$1"; else local names; names="$(jq -r '.clients[]?.email' "$(state_file)")"; if [[ -z "$names" ]]; then printf '\nNo clients. Add one: sudo hysteria2 add-client\n'; else while IFS= read -r n; do output_client_block "$n"; done <<<"$names"; fi; fi
    output_panel_hint
}
_health() { case "$1" in ok) printf '%s%s%s' "$C_GRN" "$2" "$C_OFF";; warn) printf '%s%s%s' "$C_YEL" "$2" "$C_OFF";; *) printf '%s%s%s' "$C_RED" "$2" "$C_OFF";; esac; }
output_status() {
    state_require; local rc=0 xs clients
    printf '%s\n' "$HY2_PRODUCT"; _kv 'Wrapper version' "$HY2_VERSION"; _kv '3X-UI version' "$(upstream_version || echo unknown) (validated: $TESTED_UPSTREAM)"; _kv 'Xray version' "$(upstream_xray_version || echo unknown)"
    if upstream_service_active; then _kv '3X-UI service' "$(_health ok running)"; else _kv '3X-UI service' "$(_health bad stopped)"; rc=1; fi
    if api_session_init_quiet; then xs="$(panel_xray_state)"; if [[ "$xs" == running ]]; then _kv 'Xray core' "$(_health ok running)"; else _kv 'Xray core' "$(_health bad "$xs")"; rc=1; fi; else _kv 'Xray core' "$(_health bad unavailable)"; rc=1; fi
    _kv 'Inbound endpoint' "UDP $PORT"
    if net_port_listening "$PORT"; then _kv 'Listening state' "$(_health ok listening)"; else _kv 'Listening state' "$(_health bad 'NOT listening')"; rc=1; fi
    if [[ -n "$API_TOKEN" ]] && panel_inbound_get "$INBOUND_ID"; then [[ "$(api_obj '.obj.enable')" == true ]] || rc=1; clients="$(api_obj '(.obj.clientStats//[])|length')"; _kv Inbound "$(_health ok "present (id $INBOUND_ID)")"; _kv 'Client count' "$clients"; else _kv Inbound "$(_health bad MISSING)"; rc=1; fi
    return "$rc"
}
