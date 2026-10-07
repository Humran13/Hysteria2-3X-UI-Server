#!/usr/bin/env bash
# shellcheck shell=bash
REPAIR_ACTIONS=0
_repair_note() { REPAIR_ACTIONS=$((REPAIR_ACTIONS+1)); log_ok "repaired: $*"; }

repair_inbound_problems() {
    local f="$1" sf st
    sf="$(hy2_mktemp rstream)"; st="$(hy2_mktemp rsettings)"
    jq -c '.streamSettings|if type=="string" then fromjson else . end' "$f" >"$sf"
    jq -c '.settings|if type=="string" then fromjson else . end' "$f" >"$st"
    [[ "$(jq -r .enable "$f")" == true ]] || echo 'inbound disabled'
    [[ "$(jq -r .protocol "$f")" == hysteria ]] || echo 'protocol is not hysteria'
    [[ "$(jq -r .port "$f")" == "$PORT" ]] || echo 'UDP port differs from state'
    [[ "$(jq -r .version "$st")" == 2 ]] || echo 'Hysteria protocol version is not 2'
    [[ "$(jq -r .network "$sf")" == hysteria ]] || echo 'transport is not hysteria/QUIC'
    [[ "$(jq -r .security "$sf")" == tls ]] || echo 'TLS is not enabled'
    [[ "$(jq -r '.hysteriaSettings.version' "$sf")" == 2 ]] || echo 'transport version is not 2'
    [[ "$(jq -r '.tlsSettings.serverName' "$sf")" == "$TLS_SNI" ]] || echo 'TLS server name differs'
    [[ "$(jq -r '.tlsSettings.certificates[0].certificateFile' "$sf")" == "$TLS_CERT" ]] || echo 'certificate path differs'
    [[ "$(jq -r '.tlsSettings.certificates[0].keyFile' "$sf")" == "$TLS_KEY" ]] || echo 'key path differs'
}

_repair_recreate_inbound() {
    local body; body="$(hy2_mktemp rinbound)"; inbound_build_json >"$body"
    panel_inbound_add "$body" || die "cannot recreate inbound: $API_MSG" "$HY2_EX_API"
    INBOUND_ID="$(api_obj '.obj.id')"; INBOUND_TAG="$(api_obj '.obj.tag')"
    state_update '.inbound.id=$id | .inbound.tag=$tag' --argjson id "$INBOUND_ID" --arg tag "$INBOUND_TAG"
    _repair_note "recreated Hysteria2 inbound"
}

_repair_clients() {
    local row email uuid auth en body
    while IFS= read -r row; do
        email="$(jq -r .email <<<"$row")"; uuid="$(jq -r '.uuid//""' <<<"$row")"; auth="$(jq -r .auth <<<"$row")"; en="$(jq -r .enabled <<<"$row")"
        if panel_client_get "$email"; then
            if jq -e --argjson id "$INBOUND_ID" '.obj.inboundIds//[]|index($id)!=null' "$API_OUT" >/dev/null; then continue; fi
            if jq -e '(.obj.inboundIds//[])|length==0' "$API_OUT" >/dev/null && panel_client_attach "$email" "$INBOUND_ID"; then _repair_note "re-attached client $email"; else log_warn "client $email belongs elsewhere; left untouched"; fi
            continue
        fi
        body="$(hy2_mktemp rclient)"; jq -n --arg e "$email" --arg u "$uuid" --arg a "$auth" --argjson en "$en" --argjson iid "$INBOUND_ID" '{client:{id:$u,email:$e,auth:$a,enable:$en,totalGB:0,expiryTime:0,limitIp:0,tgId:0,comment:"Hysteria2"},inboundIds:[$iid]}' >"$body"
        if panel_client_add "$body"; then _repair_note "recreated client $email"; else log_warn "could not recreate $email: $API_MSG"; fi
    done < <(jq -c '.clients[]?' "$(state_file)")
}

repair_ensure_service() { upstream_service_active && return; systemctl start "$UPSTREAM_SERVICE" || die "cannot start x-ui" "$HY2_EX_UPSTREAM"; _repair_note 'started x-ui'; }
repair_session_init() { local i; repair_ensure_service; api_configure || die "cannot determine panel URL" "$HY2_EX_API"; for ((i=0;i<60;i++)); do api_acquire_token && return; sleep 1; done; die "panel API unavailable: $API_MSG" "$HY2_EX_API"; }

repair_run() {
    local quiet="${1:-}" f problems body found
    [[ "$quiet" == quiet ]] || log_step "Inspecting managed Hysteria2 resources"
    api_ensure_own_token
    f="$(hy2_mktemp rinb)"
    if panel_inbound_get "$INBOUND_ID" && [[ "$(api_obj '.obj.remark')" == "$INBOUND_REMARK" ]]; then jq '.obj' "$API_OUT" >"$f"; else
        found="$(install_find_our_inbound)"; if [[ -n "$found" ]]; then INBOUND_ID="$(jq -r .id <<<"$found")"; INBOUND_TAG="$(jq -r .tag <<<"$found")"; state_update '.inbound.id=$id|.inbound.tag=$tag' --argjson id "$INBOUND_ID" --arg tag "$INBOUND_TAG"; jq . <<<"$found" >"$f"; else _repair_recreate_inbound; panel_inbound_get "$INBOUND_ID"; jq '.obj' "$API_OUT" >"$f"; fi
    fi
    problems="$(repair_inbound_problems "$f")"
    if [[ -n "$problems" ]]; then
        while IFS= read -r p; do log_warn "inbound: $p"; done <<<"$problems"
        body="$(hy2_mktemp rfix)"; inbound_build_json >"$body"
        panel_inbound_update "$INBOUND_ID" "$body" || die "could not repair inbound: $API_MSG" "$HY2_EX_API"
        panel_inbound_get "$INBOUND_ID" || die "repaired inbound cannot be read back" "$HY2_EX_API"
        jq '.obj' "$API_OUT" >"$f"; [[ -z "$(repair_inbound_problems "$f")" ]] || die "inbound remains inconsistent after update" "$HY2_EX_API"
        _repair_note 'restored Hysteria2 inbound settings'
    fi
    _repair_clients
    if fw_ufw_active && ! fw_rule_exists "$PORT"; then fw_open_port "$PORT"; _repair_note "restored UDP firewall rule"; fi
    if [[ "$(panel_xray_state)" != running ]]; then panel_restart_xray || true; panel_wait_xray_running 30 || log_warn "Xray still not running"; _repair_note 'restarted Xray'; fi
    net_port_listening "$PORT" || install_wait_listening || log_warn "nothing is listening on UDP $PORT"
    if [[ -x "$HY2_HOME/bin/hysteria2" && "$(readlink "$HY2_BIN_LINK" 2>/dev/null || true)" != "$HY2_HOME/bin/hysteria2" ]]; then ln -sfn "$HY2_HOME/bin/hysteria2" "$HY2_BIN_LINK"; _repair_note 'restored management command'; fi
    ((REPAIR_ACTIONS)) && state_touch || [[ "$quiet" == quiet ]] || log_ok 'Nothing to repair'
}
