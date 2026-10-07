#!/usr/bin/env bash
# shellcheck shell=bash
# firewall.sh - safe UFW interaction. We only ever ADD one allow rule for our inbound port and only DELETE rules we
# recorded ourselves. No disable/reset/flush of any firewall, no rule reordering, no default-policy changes.

FW_COMMENT="Hysteria2 3X-UI"

fw_ufw_present() { hy2_have ufw; }

fw_ufw_active() {
    fw_ufw_present || return 1
    ufw status 2>/dev/null | head -n1 | grep -qi '^Status: active'
}

# Is there already an ALLOW rule for PORT/udp (any source)?
fw_rule_exists() {
    local port="$1"
    ufw status 2>/dev/null | grep -Eq "^${port}(/udp)?[[:space:]]+ALLOW"
}

# Open PORT/udp when UFW is active. Records the rule only if we created it.
fw_open_port() {
    local port="$1"
    if ! fw_ufw_present; then
        log_info "UFW is not installed; not touching any firewall. Allow UDP $port in any provider firewall."
        return 0
    fi
    if ! fw_ufw_active; then
        log_info "UFW is installed but inactive; leaving it inactive. Allow UDP $port in any other firewall."
        return 0
    fi
    if fw_rule_exists "$port"; then
        log_info "UFW already allows UDP $port (pre-existing rule; it will not be removed on uninstall)"
        return 0
    fi
    if ufw allow "${port}/udp" comment "$FW_COMMENT" >/dev/null 2>&1; then
        state_fw_record "${port}/udp"
        log_ok "UFW: allowed ${port}/udp"
    else
        log_warn "could not add the UFW rule for ${port}/udp; please open it manually"
    fi
}

# Remove only the rules we recorded.
fw_close_ours() {
    local rule
    fw_ufw_present || return 0
    while IFS= read -r rule; do
        [[ "$rule" =~ ^[0-9]{1,5}/udp$ ]] || continue
        if fw_ufw_active && fw_rule_exists "${rule%/udp}"; then
            if ufw --force delete allow "$rule" >/dev/null 2>&1; then
                log_ok "UFW: removed our rule $rule"
            else
                log_warn "could not remove UFW rule $rule"
            fi
        fi
        state_fw_forget "$rule" || true
    done < <(jq -r '(.firewall.ufw_rules // [])[]' "$(state_file)" 2>/dev/null)
}
