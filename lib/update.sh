#!/usr/bin/env bash
# shellcheck shell=bash
# update.sh - (a) update 3X-UI to the latest STABLE release with backup + verification + rollback,
#             (b) update this wrapper from GitHub atomically.

HY2_CODELOAD="https://codeload.github.com"
[[ "${HY2_TEST_MODE:-0}" == "1" && -n "${HY2_SELF_TARBALL_URL:-}" ]] && HY2_CODELOAD="test-override"

# ---------------------------------------------------------------- panel update

# Compare vA.B.C >= vX.Y.Z (returns 0 if $1 >= $2)
_tag_ge() {
    local a="${1#v}" b="${2#v}"
    [[ "$(printf '%s\n%s\n' "$b" "$a" | sort -V | head -n1)" == "$b" ]]
}

# Post-update verification. Prints failed checks; returns non-zero on any failure.
update_verify() {
    local expect_clients="$1" f problems n first fails=0
    if [[ "${HY2_TEST_MODE:-0}" == "1" && "${HY2_TEST_FORCE_VERIFY_FAIL:-0}" == "1" ]]; then
        log_err "verify: forced failure (test hook)"
        return 1
    fi
    upstream_service_active || {
        log_err "verify: x-ui service is not active"
        fails=1
    }
    if ! api_configure || ! { api_wait_ready 90 || api_acquire_token; }; then
        log_err "verify: panel API not ready after the update: $API_MSG"
        return 1
    fi
    api_check_contract || fails=1
    panel_wait_xray_running 60 || {
        log_err "verify: Xray is not running (state: $XRAY_STATE)"
        fails=1
    }
    f="$(hy2_mktemp uinb)"
    if panel_inbound_get "$INBOUND_ID"; then
        jq '.obj' "$API_OUT" >"$f"
        problems="$(repair_inbound_problems "$f")"
        if [[ -n "$problems" ]]; then
            while IFS= read -r p; do log_err "verify: inbound: $p"; done <<<"$problems"
            fails=1
        fi
        n="$(jq -r '(.clientStats // []) | length' "$f")"
        [[ "$n" == "$expect_clients" ]] || {
            log_err "verify: client count $n != $expect_clients before the update"
            fails=1
        }
    else
        log_err "verify: managed inbound missing"
        fails=1
    fi
    net_port_listening "$PORT" || {
        log_err "verify: nothing listens on UDP $PORT"
        fails=1
    }
    first="$(state_get '(.clients // [])[0].email // empty')"
    if [[ -n "$first" ]]; then
        client_link "$first" >/dev/null 2>&1 || {
            log_err "verify: share link for $first is inconsistent"
            fails=1
        }
    fi
    ((fails == 0))
}

update_rollback() { # archive
    local archive="$1" work
    log_warn "Rolling back to the pre-update snapshot..."
    work="$(mktemp -d "$HY2_TMP/rb.XXXXXX")"
    tar -xzf "$archive" -C "$work" --no-same-owner || {
        log_err "cannot read the backup $archive"
        return 1
    }
    systemctl stop "$UPSTREAM_SERVICE" || true
    if [[ -f "$work/program.tar.gz" ]]; then
        tar -xzf "$work/program.tar.gz" -C "$UPSTREAM_DIR" --no-same-owner
        if [[ -f "$UPSTREAM_DIR/x-ui.sh" ]]; then install -m 755 "$UPSTREAM_DIR/x-ui.sh" /usr/bin/x-ui 2>/dev/null || true; fi
    else
        log_warn "the backup has no program snapshot; only the database is restored"
    fi
    # the update may have migrated the schema forward: restore the old database file while the service is stopped
    if [[ -f "$work/x-ui.db" ]]; then
        rm -f "$UPSTREAM_ETC/x-ui.db-wal" "$UPSTREAM_ETC/x-ui.db-shm"
        install -m 600 "$work/x-ui.db" "$UPSTREAM_ETC/x-ui.db"
    fi
    systemctl start "$UPSTREAM_SERVICE" || {
        log_err "x-ui did not start after the rollback (journalctl -u x-ui)"
        return 1
    }
    if ! api_configure || ! { api_wait_ready 60 || api_acquire_token; }; then
        log_err "panel API not ready after the rollback"
        return 1
    fi
    panel_wait_xray_running 60 || log_warn "Xray is not running after the rollback (state: $XRAY_STATE); try: sudo hysteria2 repair"
    log_ok "Rollback finished; 3X-UI is back at $(upstream_version || echo '?')"
}

update_panel() {
    state_require
    api_session_init
    local cur target archive expect
    cur="$(upstream_version || true)"
    [[ -n "$cur" ]] || die "cannot determine the installed 3X-UI version" "$HY2_EX_UPSTREAM"
    if [[ -n "${OPT_PANEL_VERSION:-}" ]]; then
        valid_stable_tag "$OPT_PANEL_VERSION" || die "--panel-version must be a stable tag like v3.9.0" "$HY2_EX_USAGE"
        target="$OPT_PANEL_VERSION"
    else
        target="$(upstream_latest_stable)" || die "could not determine the latest stable 3X-UI release" "$HY2_EX_UPSTREAM"
    fi
    log_info "Installed 3X-UI: $cur | target stable release: $target | wrapper tested with: $TESTED_UPSTREAM"
    if [[ "$cur" == "$target" ]]; then
        log_ok "3X-UI is already at $target; nothing to update"
        return 0
    fi
    _tag_ge "$target" "$cur" || die "target $target is older than the installed $cur; refusing to downgrade" "$HY2_EX_USAGE"
    hy2_confirm "Update 3X-UI $cur -> $target now? (a backup is taken first; your data is preserved)" y || die "update cancelled" "$HY2_EX_GENERAL"

    expect="$(jq -r '(.clients // []) | length' "$(state_file)")"
    log_step "Backing up before the update"
    archive="$(backup_create pre-update 1)"
    log_ok "Backup: $archive (versions recorded: wrapper $HY2_VERSION, 3X-UI $cur)"

    log_step "Updating"
    if ! upstream_update "$target"; then
        log_err "the official updater failed"
        update_rollback "$archive" || die "rollback failed too - restore manually from $archive (sudo hysteria2 restore $archive)" "$HY2_EX_UPSTREAM"
        die "update failed and was rolled back" "$HY2_EX_UPSTREAM"
    fi

    log_step "Verifying"
    if ! update_verify "$expect"; then
        update_rollback "$archive" || die "verification failed and rollback failed too - restore manually from $archive" "$HY2_EX_UPSTREAM"
        die "post-update verification failed; rolled back to $cur. Your configuration is unchanged." "$HY2_EX_UPSTREAM"
    fi
    state_update '.panel.version = $v | .panel.xray_version = $x | .updated_at = $now' \
        --arg v "$(upstream_version || echo "$target")" --arg x "$(upstream_xray_version || echo unknown)" --arg now "$(hy2_now_iso)" || true
    log_ok "3X-UI updated to $(upstream_version) (Xray $(upstream_xray_version || echo '?')). Inbound, clients, port and links verified."
    [[ "$target" == "$TESTED_UPSTREAM" ]] || log_warn "3X-UI $target is newer than the version this wrapper was tested against ($TESTED_UPSTREAM); everything verified fine, but consider 'hysteria2 update --self'."
}

# ---------------------------------------------------------------- wrapper self-update

# Verify SHA256SUMS inside an extracted tree; returns 0 if all listed files match.
selfupdate_verify_tree() {
    local tree="$1"
    [[ -f "$tree/SHA256SUMS" ]] || {
        log_err "SHA256SUMS missing in the downloaded tree"
        return 1
    }
    (cd "$tree" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1) || {
        log_err "checksum verification of the downloaded wrapper failed"
        return 1
    }
}

# Download REF of the wrapper repo into DEST_DIR (extracted, verified). Prints nothing.
selfupdate_fetch() { # ref dest
    local ref="$1" dest="$2" tgz top
    [[ "$ref" =~ ^[A-Za-z0-9._/-]{1,100}$ ]] || die "invalid --ref '$ref'" "$HY2_EX_USAGE"
    tgz="$(hy2_mktemp wrapper).tgz"
    if [[ "$HY2_CODELOAD" == "test-override" ]]; then
        hy2_curl "$HY2_SELF_TARBALL_URL" -o "$tgz" || return 1
    else
        hy2_curl "${HY2_CODELOAD}/${HY2_REPO}/tar.gz/${ref}" -o "$tgz" || return 1
    fi
    mkdir -p "$dest"
    tar -xzf "$tgz" -C "$dest" --strip-components=1 --no-same-owner || return 1
    top="$dest"
    [[ -f "$top/VERSION" && -x "$top/bin/hysteria2" && -d "$top/lib" ]] || {
        log_err "downloaded archive is not a complete hysteria2-3x-ui-server tree"
        return 1
    }
    selfupdate_verify_tree "$top" || return 1
    local f
    for f in "$top"/bin/hysteria2 "$top"/lib/*.sh; do
        bash -n "$f" || {
            log_err "syntax check failed for $f"
            return 1
        }
    done
    return 0
}

# Atomically install a verified tree at $HY2_HOME (keeps the old tree until the swap succeeded).
selfupdate_install_tree() { # src
    local src="$1" stage old
    stage="${HY2_HOME}.new.$$"
    old="${HY2_HOME}.old.$$"
    mkdir -p "$(dirname "$HY2_HOME")"
    rm -rf "$stage"
    mkdir -p "$stage"
    cp -a "$src/bin" "$src/lib" "$src/VERSION" "$stage/" || {
        rm -rf "$stage"
        return 1
    }
    local extra
    for extra in SHA256SUMS LICENSE NOTICE.md README.md; do
        [[ -f "$src/$extra" ]] && cp -a "$src/$extra" "$stage/"
    done
    chmod -R go-w "$stage"
    if [[ -e "$HY2_HOME" ]]; then
        mv "$HY2_HOME" "$old" || {
            rm -rf "$stage"
            return 1
        }
    fi
    if ! mv "$stage" "$HY2_HOME"; then
        [[ -e "$old" ]] && mv "$old" "$HY2_HOME"
        rm -rf "$stage"
        return 1
    fi
    rm -rf "$old"
    return 0
}

update_self() {
    hy2_require_root
    local ref="${OPT_REF:-main}" work new_ver
    work="$(mktemp -d "$HY2_TMP/self.XXXXXX")"
    log_info "Fetching $HY2_REPO@$ref ..."
    selfupdate_fetch "$ref" "$work" || die "could not fetch/verify the new wrapper version; the installed one is untouched" "$HY2_EX_UPSTREAM"
    new_ver="$(tr -d '[:space:]' <"$work/VERSION")"
    log_info "Installed wrapper: $HY2_VERSION | available: $new_ver"
    if [[ "$new_ver" == "$HY2_VERSION" && "${OPT_FORCE:-0}" != "1" ]]; then
        log_ok "wrapper is already up to date"
        return 0
    fi
    # sanity: the new tree must run
    "$work/bin/hysteria2" version >/dev/null || die "the new wrapper version does not run; keeping the installed one" "$HY2_EX_UPSTREAM"
    selfupdate_install_tree "$work" || die "could not install the new wrapper; the previous version was kept" "$HY2_EX_GENERAL"
    ln -sfn "$HY2_HOME/bin/hysteria2" "$HY2_BIN_LINK" 2>/dev/null || true
    log_ok "Wrapper updated: $HY2_VERSION -> $new_ver (your state and backups were not touched)"
}
