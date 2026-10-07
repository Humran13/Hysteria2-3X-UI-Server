#!/usr/bin/env bash
# shellcheck shell=bash
DIAG_FAILS=0 DIAG_WARNS=0
_d_pass(){ printf '  [PASS] %s\n' "$*"; }
_d_warn(){ DIAG_WARNS=$((DIAG_WARNS+1)); printf '  [WARN] %s\n' "$*"; }
_d_fail(){ DIAG_FAILS=$((DIAG_FAILS+1)); printf '  [FAIL] %s\n' "$*"; }
diagnostics_run() {
    state_require; DIAG_FAILS=0; DIAG_WARNS=0; local f problems name link
    printf '%s diagnostics\n\n' "$HY2_PRODUCT"
    if upstream_service_active; then _d_pass 'x-ui service active'; else _d_fail 'x-ui service stopped'; fi
    if api_session_init_quiet; then _d_pass 'panel API reachable'; if [[ "$(panel_xray_state)" == running ]]; then _d_pass 'Xray core running'; else _d_fail 'Xray core not running'; fi; else _d_fail "panel API unavailable: $API_MSG"; fi
    f="$(hy2_mktemp diag-inbound)"
    if panel_inbound_get "$INBOUND_ID"; then jq '.obj' "$API_OUT" >"$f"; problems="$(repair_inbound_problems "$f")"; if [[ -z "$problems" ]]; then _d_pass 'Hysteria2 inbound fields match state'; else _d_fail "inbound mismatch: $problems"; fi; else _d_fail 'managed inbound missing'; fi
    if net_port_listening "$PORT"; then _d_pass "UDP $PORT is listening ($(net_port_listeners "$PORT"))"; else _d_fail "UDP $PORT is not listening"; fi
    if fw_ufw_active; then if fw_rule_exists "$PORT"; then _d_pass "UFW allows UDP $PORT"; else _d_fail "UFW blocks UDP $PORT"; fi; else _d_warn 'UFW inactive/not installed; another firewall may still apply'; fi
    _d_warn "cloud firewalls cannot be inspected; confirm inbound UDP $PORT"
    if [[ -r "$TLS_CERT" && -r "$TLS_KEY" ]]; then _d_pass 'TLS certificate and key readable'; else _d_fail 'TLS files missing'; fi
    if hysteria_validate_cert_key "$TLS_CERT" "$TLS_KEY"; then _d_pass 'TLS certificate matches private key'; else _d_fail 'TLS certificate/key mismatch'; fi
    while IFS= read -r name; do [[ -n "$name" ]] || continue; link="$(client_link "$name" 2>/dev/null || true)"; if [[ "$link" == hysteria2://* || "$link" == hy2://* ]]; then _d_pass "share URI valid for $name"; else _d_fail "share URI invalid for $name"; fi; done < <(state_get '.clients[]?.email')
    printf '\nResult: %d failure(s), %d warning(s)\n' "$DIAG_FAILS" "$DIAG_WARNS"; ((DIAG_FAILS==0))
}
