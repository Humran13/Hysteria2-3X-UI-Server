#!/usr/bin/env bash
# shellcheck shell=bash
# Client operations use 3X-UI's supported v3 client API.

# shellcheck disable=SC2016
CLIENT_UPDATE_JQ='.obj.client | {id:.uuid,email,subId,auth,limitIp,limitHwid,totalGB,expiryTime,enable:$en,tgId,group,comment,reset,resetDay,resetMax,resetWeekday,trafficReset,trafficResetDay}'

client_fetch() {
    local name="$1"
    valid_client_name "$name" || die "invalid client name '$name'" "$HY2_EX_USAGE"
    panel_client_get "$name" || die "client '$name' not found ($API_MSG)" "$HY2_EX_STATE"
    jq -e --argjson id "$INBOUND_ID" '.obj.inboundIds // [] | index($id) != null' "$API_OUT" >/dev/null ||
        die "client '$name' is not attached to the managed Hysteria2 inbound; refusing to touch it" "$HY2_EX_STATE"
}

client_next_default_name() {
    local i=1 existing
    panel_clients_list || die "cannot list clients: $API_MSG" "$HY2_EX_API"
    existing="$(api_obj '[.obj[].email] | join("\n")')"
    while grep -qxF "client$i" <<<"$existing"; do i=$((i + 1)); done
    printf 'client%s' "$i"
}

client_create() {
    local name="$1" days="${2:-0}" gb="${3:-0}" body expiry=0 bytes=0 uuid auth
    valid_client_name "$name" || die "invalid client name '$name' (letters, digits, . _ -; max 64)" "$HY2_EX_USAGE"
    valid_nonneg_int "$days" || die "invalid --expire-days '$days'" "$HY2_EX_USAGE"
    valid_nonneg_int "$gb" || die "invalid --quota-gb '$gb'" "$HY2_EX_USAGE"
    ((days > 0)) && expiry=$((($(date +%s) + days * 86400) * 1000))
    ((gb > 0)) && bytes=$((gb * 1073741824))
    if panel_client_get "$name"; then
        if jq -e --argjson id "$INBOUND_ID" '.obj.inboundIds // [] | index($id) != null' "$API_OUT" >/dev/null; then
            auth="$(api_obj '.obj.client.auth // empty')"; uuid="$(api_obj '.obj.client.uuid // empty')"
            [[ -n "$auth" ]] || die "existing Hysteria2 client '$name' has no auth credential" "$HY2_EX_STATE"
            state_client_upsert "$name" "$uuid" "$auth" "$(api_obj '.obj.client.enable')" || true
            log_info "client '$name' already exists; nothing to do"; return 0
        fi
        die "a panel client named '$name' already exists outside the managed inbound" "$HY2_EX_STATE"
    fi
    auth="$(hy2_random_alnum 32)"; body="$(hy2_mktemp client)"; hy2_secret_add "$auth"
    jq -n --arg e "$name" --arg a "$auth" --argjson total "$bytes" --argjson exp "$expiry" --argjson iid "$INBOUND_ID" \
      '{client:{email:$e,auth:$a,enable:true,totalGB:$total,expiryTime:$exp,limitIp:0,tgId:0,comment:"Hysteria2"},inboundIds:[$iid]}' >"$body"
    panel_client_add "$body" || die "could not create client '$name': $API_MSG" "$HY2_EX_API"
    panel_client_get "$name" || die "client was created but cannot be read back: $API_MSG" "$HY2_EX_API"
    uuid="$(api_obj '.obj.client.uuid // empty')"
    [[ "$(api_obj '.obj.client.auth // empty')" == "$auth" ]] || die "panel did not store the expected Hysteria2 auth credential" "$HY2_EX_API"
    state_client_upsert "$name" "$uuid" "$auth" true || log_warn "could not update local state"
    log_ok "Client created: $name"
}

client_set_enabled() {
    local name="$1" en="$2" body
    client_fetch "$name"; body="$(hy2_mktemp cupd)"; jq --argjson en "$en" "$CLIENT_UPDATE_JQ" "$API_OUT" >"$body"
    panel_client_update "$name" "$body" || die "could not update client '$name': $API_MSG" "$HY2_EX_API"
    panel_client_get "$name" || die "cannot read back client '$name'" "$HY2_EX_API"
    [[ "$(api_obj '.obj.client.enable')" == "$en" ]] || die "panel did not apply enable=$en" "$HY2_EX_API"
    state_client_upsert "$name" "$(api_obj '.obj.client.uuid // empty')" "$(api_obj '.obj.client.auth')" "$en" || true
    log_ok "Client $([[ $en == true ]] && echo enabled || echo disabled): $name"
}

client_remove() { local name="$1"; client_fetch "$name"; panel_client_del "$name" || die "could not remove client '$name': $API_MSG" "$HY2_EX_API"; state_client_remove "$name" || true; log_ok "Client removed: $name"; }

client_link() {
    local name="$1" link auth problems rc=0
    client_fetch "$name"; auth="$(api_obj '.obj.client.auth // empty')"
    panel_client_links "$name" || die "could not get share link for '$name': $API_MSG" "$HY2_EX_API"
    link="$(api_obj '[.obj[]? | select(startswith("hysteria2://") or startswith("hy2://"))][0] // empty')"
    [[ -n "$link" ]] || die "the panel returned no Hysteria2 share link for '$name'" "$HY2_EX_API"
    problems="$(link_validate "$link" "$auth")" || rc=1
    if ((rc)); then log_warn "share link validation failed: $problems"; fi
    printf '%s\n' "$link"; return "$rc"
}

client_qr() { local link; hy2_have qrencode || { log_warn "install qrencode to render terminal QR codes"; return 1; }; link="$(client_link "$1")" || true; [[ -n "$link" ]] && qrencode -t ANSIUTF8 -m 1 "$link"; }
human_bytes() { local b="${1:-0}"; if ((b>=1073741824)); then printf '%d.%02d GB' $((b/1073741824)) $(((b%1073741824)*100/1073741824)); elif ((b>=1048576)); then printf '%d MB' $((b/1048576)); else printf '%d KB' $((b/1024)); fi; }
client_list() {
    panel_clients_list || die "cannot list clients: $API_MSG" "$HY2_EX_API"
    local rows name en used total exp expfmt totfmt
    rows="$(jq -c --argjson id "$INBOUND_ID" '.obj[] | select((.inboundIds // []) | index($id) != null)' "$API_OUT")"
    printf '%-28s %-9s %-10s %-12s %-12s\n' NAME STATUS USED QUOTA EXPIRES
    while IFS= read -r row; do [[ -n "$row" ]] || continue; name="$(jq -r .email <<<"$row")"; en="$(jq -r .enable <<<"$row")"; used="$(jq -r '((.traffic.up//0)+(.traffic.down//0))' <<<"$row")"; total="$(jq -r '.totalGB//0' <<<"$row")"; exp="$(jq -r '.expiryTime//0' <<<"$row")"; totfmt=unlimited; ((total>0)) && totfmt="$(human_bytes "$total")"; expfmt=never; ((exp>0)) && expfmt="$(date -u -d "@$((exp/1000))" +%F 2>/dev/null || echo "$exp")"; printf '%-28s %-9s %-10s %-12s %-12s\n' "$name" "$([[ $en == true ]] && echo enabled || echo disabled)" "$(human_bytes "$used")" "$totfmt" "$expfmt"; done <<<"$rows"
}
