#!/usr/bin/env bash
# shellcheck shell=bash
# Idempotent fresh-host installation flow.

PANEL_MARKER_NAME=".panel-installed-by-wrapper"
installer_panel_marker() { printf '%s/%s' "$HY2_STATE_DIR" "$PANEL_MARKER_NAME"; }

install_choose_port() {
    local p owners
    p="${OPT_PORT:-443}"; valid_port "$p" || die "invalid --port '$p'" "$HY2_EX_USAGE"; p="$((10#$p))"
    while net_port_in_use "$p"; do
        owners="$(net_port_listeners "$p")"
        log_warn "UDP port $p is already in use by ${owners:-another process}; it will not be stopped."
        if [[ -n "${OPT_PORT:-}" || $HY2_INTERACTIVE -eq 0 ]]; then
            die "UDP port $p is occupied; re-run with --port <free UDP port> (for example 8443)" "$HY2_EX_ENV"
        fi
        hy2_ask p "Enter another UDP port for Hysteria2" "8443"
        valid_port "$p" || { p=443; continue; }; p="$((10#$p))"
    done
    PORT="$p"
}

install_choose_address() {
    if [[ -n "${OPT_SERVER_ADDRESS:-}" ]]; then valid_server_address "$OPT_SERVER_ADDRESS" || die "invalid --server-address" "$HY2_EX_USAGE"; SERVER_ADDR="$OPT_SERVER_ADDRESS"; return; fi
    SERVER_ADDR="$(net_detect_public_ip || true)"
    if [[ -z "$SERVER_ADDR" ]]; then
        ((HY2_INTERACTIVE)) || die "could not detect the public IPv4 address; pass --server-address" "$HY2_EX_ENV"
        hy2_ask SERVER_ADDR "Public IPv4 address or hostname" ""
    fi
    valid_server_address "$SERVER_ADDR" || die "invalid server address '$SERVER_ADDR'" "$HY2_EX_USAGE"
    log_info "Public endpoint: $SERVER_ADDR"
}

install_ensure_panel() {
    local tag
    state_dir_init
    if upstream_installed; then
        log_info "Existing 3X-UI detected ($(upstream_version || echo unknown)); preserving it."
        [[ -e "$(installer_panel_marker)" ]] && PANEL_BY_US=true
        upstream_service_active || systemctl start "$UPSTREAM_SERVICE" || die "could not start x-ui" "$HY2_EX_UPSTREAM"
        api_configure || die "cannot determine the panel URL" "$HY2_EX_API"
        api_acquire_token || die "cannot authenticate to existing 3X-UI. Create an API token, then re-run with HY2_XUI_API_TOKEN='<token>'." "$HY2_EX_API"
    else
        tag="${OPT_PANEL_VERSION:-$(upstream_latest_stable || true)}"
        valid_stable_tag "$tag" || die "could not resolve a stable 3X-UI release" "$HY2_EX_UPSTREAM"
        log_step "Installing official 3X-UI $tag"
        : >"$(installer_panel_marker)"; chmod 600 "$(installer_panel_marker)"; PANEL_BY_US=true
        upstream_install "$tag" || die "official 3X-UI installation failed" "$HY2_EX_UPSTREAM"
        api_configure || die "cannot determine the panel URL" "$HY2_EX_API"
        upstream_result_load || die "3X-UI installed but its API token result is unavailable" "$HY2_EX_UPSTREAM"
        api_set_token "$XUI_API_TOKEN"; API_TOKEN_SOURCE=result
        api_wait_ready 90 || die "3X-UI API did not become ready" "$HY2_EX_UPSTREAM"
    fi
    api_check_contract || die "incompatible 3X-UI API" "$HY2_EX_UPSTREAM"
    api_ensure_own_token
}

install_find_our_inbound() {
    panel_inbounds_list || die "cannot list inbounds: $API_MSG" "$HY2_EX_API"
    jq -c --arg r "$INBOUND_REMARK" '.obj // [] | map(select(.remark==$r and .protocol=="hysteria")) | .[0] // empty' "$API_OUT"
}

install_validate_inbound_file() {
    local f="$1"
    jq -e --argjson p "$PORT" --arg cert "$TLS_CERT" --arg key "$TLS_KEY" '
      .enable==true and .protocol=="hysteria" and .port==$p and
      ((.settings|if type=="string" then fromjson else . end).version==2) and
      ((.streamSettings|if type=="string" then fromjson else . end) as $s |
        $s.network=="hysteria" and $s.security=="tls" and $s.hysteriaSettings.version==2 and
        $s.tlsSettings.certificates[0].certificateFile==$cert and $s.tlsSettings.certificates[0].keyFile==$key)' "$f" >/dev/null
}

install_create_inbound() {
    local body live
    body="$(hy2_mktemp inbound)"; inbound_build_json >"$body"
    panel_inbound_add "$body" || die "the panel refused the Hysteria2 inbound: $API_MSG" "$HY2_EX_API"
    INBOUND_ID="$(api_obj '.obj.id // empty')"; INBOUND_TAG="$(api_obj '.obj.tag // empty')"
    [[ "$INBOUND_ID" =~ ^[0-9]+$ ]] || die "panel returned no inbound id" "$HY2_EX_API"
    panel_inbound_get "$INBOUND_ID" || die "created inbound cannot be read back" "$HY2_EX_API"
    live="$(hy2_mktemp live-inbound)"; jq '.obj' "$API_OUT" >"$live"
    install_validate_inbound_file "$live" || { panel_inbound_del "$INBOUND_ID" >/dev/null 2>&1 || true; die "3X-UI did not persist the expected Hysteria2/UDP/TLS fields; inbound rolled back" "$HY2_EX_API"; }
    state_create || die "cannot write state" "$HY2_EX_STATE"
    log_ok "Hysteria2 inbound created and read-back verified (id $INBOUND_ID, UDP $PORT)"
}

adopt_inbound() {
    local inb="$1" sf settings rows row email
    sf="$(hy2_mktemp adopt)"; jq -c '.streamSettings | if type=="string" then fromjson else . end' <<<"$inb" >"$sf"
    settings="$(hy2_mktemp adopt-settings)"; jq -c '.settings | if type=="string" then fromjson else . end' <<<"$inb" >"$settings"
    [[ "$(jq -r '.version' "$settings")" == 2 && "$(jq -r '.network' "$sf")" == hysteria ]] || die "existing Hysteria remark is not a version-2 Hysteria inbound" "$HY2_EX_STATE"
    INBOUND_ID="$(jq -r .id <<<"$inb")"; INBOUND_TAG="$(jq -r .tag <<<"$inb")"; PORT="$(jq -r .port <<<"$inb")"
    SERVER_ADDR="$(jq -r '.shareAddr // empty' <<<"$inb")"; [[ -n "$SERVER_ADDR" ]] || install_choose_address
    TLS_CERT="$(jq -r '.tlsSettings.certificates[0].certificateFile // empty' "$sf")"; TLS_KEY="$(jq -r '.tlsSettings.certificates[0].keyFile // empty' "$sf")"
    TLS_SNI="$(jq -r '.tlsSettings.serverName // empty' "$sf")"; TLS_PIN="$(jq -r '.tlsSettings.settings.pinnedPeerCertSha256[0] // empty' "$sf")"
    TLS_MODE="$([[ -n $TLS_PIN ]] && echo self-signed-pinned || echo provided)"
    [[ -r "$TLS_CERT" && -r "$TLS_KEY" ]] || die "existing inbound TLS files are missing; not adopting" "$HY2_EX_STATE"
    state_create
    panel_clients_list || return 0
    rows="$(hy2_mktemp adopt-clients)"; jq -c --argjson id "$INBOUND_ID" '.obj[] | select((.inboundIds//[])|index($id)!=null)' "$API_OUT" >"$rows"
    while IFS= read -r row; do email="$(jq -r .email <<<"$row")"; panel_client_get "$email" || continue; state_client_upsert "$email" "$(api_obj '.obj.client.uuid // empty')" "$(api_obj '.obj.client.auth // empty')" "$(api_obj '.obj.client.enable')" || true; done <"$rows"
    log_ok "Adopted existing Hysteria2 inbound $INBOUND_ID"
}

install_wait_listening() { local i; for ((i=0;i<45;i++)); do net_port_listening "$PORT" && return 0; if ((i==12)); then panel_restart_xray >/dev/null 2>&1 || true; fi; sleep 1; done; return 1; }

install_validate_options() {
    [[ -z "${OPT_PORT:-}" ]] || valid_port "$OPT_PORT" || die "invalid --port" "$HY2_EX_USAGE"
    [[ -z "${OPT_SERVER_ADDRESS:-}" ]] || valid_server_address "$OPT_SERVER_ADDRESS" || die "invalid --server-address" "$HY2_EX_USAGE"
    [[ -z "${OPT_SNI:-}" ]] || valid_sni "$OPT_SNI" || die "invalid --sni" "$HY2_EX_USAGE"
    [[ -z "${OPT_CLIENT_NAME:-}" ]] || valid_client_name "$OPT_CLIENT_NAME" || die "invalid --client-name" "$HY2_EX_USAGE"
    [[ -z "${OPT_PANEL_VERSION:-}" ]] || valid_stable_tag "$OPT_PANEL_VERSION" || die "invalid --panel-version" "$HY2_EX_USAGE"
    [[ -z "${OPT_TLS_CERT:-}${OPT_TLS_KEY:-}" || ( -n "${OPT_TLS_CERT:-}" && -n "${OPT_TLS_KEY:-}" ) ]] || die "--tls-cert and --tls-key must be supplied together" "$HY2_EX_USAGE"
}

installer_run() {
    output_banner; hy2_require_root; hy2_tmp_init; hy2_lock; install_validate_options
    log_step "Checking the system"; os_check_all; os_install_deps
    if state_exists; then
        log_info "A managed Hysteria2 setup exists; verifying it instead of duplicating resources."
        state_load; repair_session_init; install_management_command; repair_run quiet
        [[ "$(state_get '(.clients//[])|length')" != 0 ]] || client_create "${OPT_CLIENT_NAME:-$DEFAULT_CLIENT_NAME}"
        output_info; return
    fi
    log_step "3X-UI panel"; install_ensure_panel
    local existing; existing="$(install_find_our_inbound)"
    if [[ -n "$existing" ]]; then adopt_inbound "$existing"; else
        log_step "Preparing Hysteria2"; install_choose_address; install_choose_port; hysteria_prepare_tls; install_create_inbound
    fi
    log_step "Creating the first client"; [[ "$(state_get '(.clients//[])|length')" != 0 ]] || client_create "${OPT_CLIENT_NAME:-$DEFAULT_CLIENT_NAME}"
    log_step "Firewall"; fw_open_port "$PORT"
    log_step "Verifying"; panel_wait_xray_running 45 || die "Xray core is not running ($XRAY_STATE)" "$HY2_EX_STATE"
    install_wait_listening || die "the expected service is not listening on UDP $PORT" "$HY2_EX_STATE"
    local first; first="$(state_get '(.clients//[])[0].email')"; client_link "$first" >/dev/null || die "generated share link failed validation" "$HY2_EX_STATE"
    install_management_command; state_touch || true
    printf '\n%s\n' "${C_GRN}Installation complete.${C_OFF}" >&2; output_connection_details; output_client_block "$first"
    if hy2_have qrencode; then printf '\nScan this QR code:\n'; client_qr "$first" || true; fi
    output_panel_hint; printf '\nManage with: sudo hysteria2 menu\n'; fw_reminder
}

fw_reminder() { printf '\nIf your VPS provider has a cloud firewall, allow inbound UDP %s. TCP-only is not sufficient.\n' "$PORT"; }
install_management_command() {
    local target="$HY2_HOME/bin/hysteria2"
    if [[ "$HY2_ROOT_DIR" != "$HY2_HOME" && -x "$HY2_ROOT_DIR/bin/hysteria2" && ! -e "$target" ]]; then selfupdate_install_tree "$HY2_ROOT_DIR" || log_warn "could not install the wrapper tree"; fi
    [[ -x "$target" ]] && ln -sfn "$target" "$HY2_BIN_LINK" && log_ok "Management command: $HY2_BIN_LINK"
}
