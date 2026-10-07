#!/usr/bin/env bash
# shellcheck shell=bash
# Root-only state identifies exactly the resources this wrapper owns.

PORT="" SERVER_ADDR="" INBOUND_ID="" INBOUND_TAG=""
PANEL_BY_US="false" STATE_API_TOKEN_ID=""

state_file() { printf '%s/state.json' "$HY2_STATE_DIR"; }
state_dir_init() { mkdir -p "$HY2_STATE_DIR"; chmod 700 "$HY2_STATE_DIR"; }
state_exists() { [[ -s "$(state_file)" ]] && jq -e 'type == "object"' "$(state_file)" >/dev/null 2>&1; }
state_require() { state_exists || die "no managed Hysteria2 setup found. Run: sudo hysteria2 install" "$HY2_EX_STATE"; state_load; }
state_get() { jq -r "$1" "$(state_file)"; }
state_update() {
    local prog="$1" f tmp; shift; state_dir_init; f="$(state_file)"; tmp="$(mktemp "$HY2_STATE_DIR/.state.XXXXXX")" || return 1
    if [[ -s "$f" ]]; then jq "$@" "$prog" "$f" >"$tmp"; else jq -n "$@" "null | $prog" >"$tmp"; fi || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp"; mv -f "$tmp" "$f"
}
state_load() {
    local -a v=()
    mapfile -t v < <(jq -r '(.inbound.port // ""), (.server_address // ""), (.inbound.id // ""), (.inbound.tag // ""),
      (.tls.mode // ""), (.tls.cert // ""), (.tls.key // ""), (.tls.sni // ""), (.tls.pin_sha256 // ""),
      (.panel.installed_by_us // false | tostring), (.api_token_id // "" | tostring)' "$(state_file)")
    PORT="${v[0]}" SERVER_ADDR="${v[1]}" INBOUND_ID="${v[2]}" INBOUND_TAG="${v[3]}"
    TLS_MODE="${v[4]}" TLS_CERT="${v[5]}" TLS_KEY="${v[6]}" TLS_SNI="${v[7]}" TLS_PIN="${v[8]}"
    PANEL_BY_US="${v[9]}" STATE_API_TOKEN_ID="${v[10]}"
}
state_create() {
    state_update '{schema: 2, wrapper_version: $wv, installed_at: $now, updated_at: $now,
      panel: {installed_by_us: ($by == "true"), version: $pv, xray_version: $xv}, server_address: $addr, api_token_id: $tid,
      inbound: {id: $iid, tag: $itag, remark: "Hysteria2", port: $port, transport: "udp"},
      tls: {mode: $tm, cert: $cert, key: $key, sni: $sni, pin_sha256: $pin}, clients: [], firewall: {ufw_rules: []}}' \
      --arg wv "$HY2_VERSION" --arg now "$(hy2_now_iso)" --arg by "$PANEL_BY_US" \
      --arg pv "$(upstream_version || echo unknown)" --arg xv "$(upstream_xray_version || echo unknown)" \
      --arg addr "$SERVER_ADDR" --arg tid "${API_TOKEN_ID:-}" --argjson iid "$INBOUND_ID" --arg itag "$INBOUND_TAG" --argjson port "$PORT" \
      --arg tm "$TLS_MODE" --arg cert "$TLS_CERT" --arg key "$TLS_KEY" --arg sni "$TLS_SNI" --arg pin "$TLS_PIN"
}
state_touch() { state_update '.updated_at=$now | .wrapper_version=$wv' --arg now "$(hy2_now_iso)" --arg wv "$HY2_VERSION"; }
state_client_upsert() { state_update '.clients=((.clients // []) | map(select(.email != $e)) + [{email:$e,uuid:$u,auth:$a,enabled:($en=="true")}]) | .updated_at=$now' --arg e "$1" --arg u "$2" --arg a "$3" --arg en "$4" --arg now "$(hy2_now_iso)"; }
state_client_remove() { state_update '.clients=((.clients // []) | map(select(.email != $e)))' --arg e "$1"; }
state_has_client() { [[ "$(jq -r --arg e "$1" '[.clients[]? | select(.email==$e)]|length' "$(state_file)")" != 0 ]]; }
state_fw_record() { state_update '.firewall.ufw_rules=(((.firewall.ufw_rules // [])+[$r])|unique)' --arg r "$1"; }
state_fw_forget() { state_update '.firewall.ufw_rules=((.firewall.ufw_rules // [])|map(select(. != $r)))' --arg r "$1"; }
