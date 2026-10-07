#!/usr/bin/env bash
# shellcheck shell=bash
# uninstall.sh - three clearly separated levels. Only level 3 touches upstream 3X-UI.
#   1  remove managed Hysteria2 resources (inbound, clients, token, TLS files, firewall rule, state)
#   2  level 1 + remove the wrapper itself (/opt/hysteria2-3x-ui-server, management command)
#   3  level 2 + remove 3X-UI via its official uninstaller
# Unrelated inbounds/clients are never deleted by levels 1-2. Backups are kept.

_uninstall_level1() {
    local email n_removed=0 tmp
    log_step "Removing managed Hysteria2 configuration"
    if state_exists; then
        state_load
        if api_session_init_quiet; then
            local bk
            bk="$(backup_create pre-uninstall)" && log_ok "Backup saved: $bk"
            # our clients first (only those attached to OUR inbound), then the inbound itself
            tmp="$(hy2_mktemp ulist)"
            if panel_clients_list; then
                jq -r --argjson id "$INBOUND_ID" '.obj[] | select((.inboundIds // []) == [$id]) | .email' "$API_OUT" >"$tmp"
                # Orphans that we created and recorded.
                jq -r --slurpfile st "$(state_file)" '($st[0].clients // [] | map(.email)) as $ours
                    | .obj[] | select((.inboundIds // []) == [] and ((.comment // "") == "Hysteria2" or (.email as $e | $ours | index($e) != null))) | .email' "$API_OUT" >>"$tmp"
                while IFS= read -r email; do
                    [[ -n "$email" ]] || continue
                    if panel_client_del "$email"; then n_removed=$((n_removed + 1)); else log_warn "could not remove client $email: $API_MSG"; fi
                done <"$tmp"
            fi
            if panel_inbound_get "$INBOUND_ID" && [[ "$(api_obj '.obj.remark // ""')" == "$INBOUND_REMARK" && "$(api_obj '.obj.protocol // ""')" == "hysteria" ]]; then
                if panel_inbound_del "$INBOUND_ID"; then
                    log_ok "Removed inbound $INBOUND_ID and $n_removed client(s)"
                else
                    log_warn "could not delete inbound $INBOUND_ID: $API_MSG"
                fi
            else
                log_info "managed inbound is already gone from the panel"
            fi
            # our token(s) last: after this the stored token no longer works
            api_delete_all_own_tokens
        else
            log_warn "panel API unavailable ($API_MSG): remove the inbound named Hysteria2 manually"
        fi
        fw_close_ours
    else
        log_info "no wrapper state found; nothing to remove at this level"
    fi
    rm -f "$HY2_STATE_DIR/state.json" "$HY2_STATE_DIR/api-token" "$HY2_STATE_DIR/.state."* 2>/dev/null || true
    rm -rf -- "$HY2_STATE_DIR/tls" 2>/dev/null || true
}

_uninstall_level2() {
    log_step "Removing the wrapper"
    if [[ "$(readlink "$HY2_BIN_LINK" 2>/dev/null || true)" == "$HY2_HOME/bin/hysteria2" ]]; then
        rm -f "$HY2_BIN_LINK"
        log_ok "Removed $HY2_BIN_LINK"
    fi
    rm -f "$HY2_STATE_DIR/.panel-installed-by-wrapper"
    rmdir "$HY2_STATE_DIR" 2>/dev/null || true
    if [[ -d "$HY2_HOME" ]]; then
        rm -rf -- "$HY2_HOME"
        log_ok "Removed $HY2_HOME"
    fi
    log_info "Backups were kept in $HY2_BACKUP_DIR (delete them yourself when no longer needed)."
}

_uninstall_level3() {
    log_step "Removing 3X-UI (official uninstaller)"
    if ! upstream_installed; then
        log_info "3X-UI is not installed"
        return 0
    fi
    upstream_uninstall || die "the official 3X-UI uninstaller failed" "$HY2_EX_UPSTREAM"
    upstream_installed && die "3X-UI is still present after uninstall" "$HY2_EX_UPSTREAM"
    log_ok "3X-UI removed"
}

# uninstall_run  (uses OPT_UNINSTALL_LEVEL, HY2_ASSUME_YES)
uninstall_run() {
    hy2_require_root
    hy2_tmp_init
    hy2_lock
    local level="${OPT_UNINSTALL_LEVEL:-}"
    if [[ -z "$level" ]]; then
        ((HY2_INTERACTIVE)) || die "choose what to remove with --level 1|2|3 (non-interactive)" "$HY2_EX_USAGE"
        cat >&2 <<'EOF'
What do you want to remove?

  1. Remove managed Hysteria2 configuration only
  2. Remove wrapper + managed configuration
  3. Remove wrapper + managed configuration + 3X-UI (ALL panel data, including unrelated inbounds/clients)
EOF
        hy2_ask level "Choose [1-3]" ""
    fi
    [[ "$level" =~ ^[123]$ ]] || die "invalid level '$level' (use 1, 2 or 3)" "$HY2_EX_USAGE"

    state_exists && state_load
    case "$level" in
        1) hy2_confirm "Remove the managed inbound, its clients and our firewall rule? (a backup is taken first)" n || die "cancelled" "$HY2_EX_GENERAL" ;;
        2) hy2_confirm "Remove the managed configuration AND the wrapper itself? (a backup is taken first)" n || die "cancelled" "$HY2_EX_GENERAL" ;;
        3)
            if [[ "$PANEL_BY_US" != "true" ]]; then
                log_warn "3X-UI was NOT installed by this tool; removing it deletes every inbound and client in it."
            fi
            hy2_confirm_typed "This removes 3X-UI completely, including ALL its inbounds, clients and settings (a database backup is taken first)." "REMOVE-3XUI" || die "cancelled" "$HY2_EX_GENERAL"
            ;;
    esac

    # level 3 needs a DB backup even when we have no state to speak of
    if [[ "$level" == "3" ]] && ! state_exists && upstream_installed; then
        if api_session_init_quiet; then
            local bk
            bk="$(backup_create pre-uninstall)" && log_ok "Backup saved: $bk"
        else
            log_warn "could not back up the panel database ($API_MSG)"
        fi
    fi

    _uninstall_level1
    [[ "$level" == "1" ]] && {
        log_ok "Done. The wrapper is still installed; run 'sudo hysteria2 install' to set up again."
        return 0
    }
    if [[ "$level" == "3" ]]; then
        _uninstall_level3
    fi
    _uninstall_level2
    log_ok "Done."
}
