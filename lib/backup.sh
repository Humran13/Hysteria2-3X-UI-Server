#!/usr/bin/env bash
# shellcheck shell=bash
# backup.sh - backup / restore. The panel database is taken through the official API (consistent SQLite snapshot);
# wrapper state is copied alongside. Archives are root-only (0600) in a 0700 directory.
#
# Archive layout (tar.gz): manifest.json, x-ui.db, state/ (wrapper state dir), [program.tar.gz  (optional, update rollback)]

backup_dir_init() {
    [[ -d "$HY2_BACKUP_DIR" ]] || (umask 077 && mkdir -p "$HY2_BACKUP_DIR") || die "cannot create $HY2_BACKUP_DIR" "$HY2_EX_ENV"
    chmod 700 "$HY2_BACKUP_DIR"
}

# backup_create [label] [with_program]  -> prints the archive path on stdout
backup_create() {
    local label="${1:-manual}" with_program="${2:-0}" stamp work out
    backup_dir_init
    stamp="$(hy2_now_stamp)"
    work="$(mktemp -d "$HY2_TMP/bk.XXXXXX")"
    out="$HY2_BACKUP_DIR/hysteria2-backup-${label}-${stamp}.tar.gz"

    # 1. panel database via the official backup endpoint
    if [[ -n "$API_TOKEN" ]] && api_download /panel/api/server/getDb "$work/x-ui.db" && head -c 15 "$work/x-ui.db" 2>/dev/null | grep -q 'SQLite format 3'; then
        log_debug "database snapshot taken through the panel API"
    elif ! upstream_service_active && [[ -f "$UPSTREAM_ETC/x-ui.db" ]]; then
        # service stopped -> the file is quiescent (WAL merged on close)
        cp -p "$UPSTREAM_ETC/x-ui.db" "$work/x-ui.db"
        [[ -f "$UPSTREAM_ETC/x-ui.db-wal" ]] && cp -p "$UPSTREAM_ETC/x-ui.db-wal" "$work/x-ui.db-wal"
        log_warn "panel is stopped; copied the database file directly"
    else
        rm -rf "$work"
        die "could not take a database backup through the panel API ($API_MSG)" "$HY2_EX_API"
    fi

    # 2. wrapper state
    mkdir -p "$work/state"
    if [[ -d "$HY2_STATE_DIR" ]]; then
        cp -a "$HY2_STATE_DIR/." "$work/state/" 2>/dev/null || true
    fi

    # 3. optional program snapshot (used to roll back a failed panel update)
    if [[ "$with_program" == "1" && -d "$UPSTREAM_DIR" ]]; then
        (cd "$UPSTREAM_DIR" && tar -czf "$work/program.tar.gz" --exclude='bin/geo*.dat' . ) || log_warn "could not snapshot the 3X-UI program directory"
    fi

    jq -n --arg wv "$HY2_VERSION" --arg uv "$(upstream_version || echo unknown)" --arg xv "$(upstream_xray_version || echo unknown)" \
        --arg now "$(hy2_now_iso)" --arg kind "$label" --argjson prog "$([[ -f "$work/program.tar.gz" ]] && echo true || echo false)" \
        '{format: 2, created_at: $now, kind: $kind, wrapper_version: $wv, panel_version: $uv, xray_version: $xv, protocol: "hysteria2", has_program: $prog}' >"$work/manifest.json" || {
        rm -rf "$work"
        die "failed to write backup manifest" "$HY2_EX_ENV"
    }

    (umask 077 && tar -czf "$out" -C "$work" .) || die "failed to write backup archive" "$HY2_EX_ENV"
    chmod 600 "$out"
    rm -rf "$work"
    printf '%s' "$out"
}

backup_list() {
    backup_dir_init
    local f n=0
    for f in "$HY2_BACKUP_DIR"/hysteria2-backup-*.tar.gz; do
        [[ -e "$f" ]] || continue
        printf '  %s  (%s)\n' "$f" "$(du -h "$f" | cut -f1)"
        n=$((n + 1))
    done
    ((n > 0)) || echo "  (no backups yet)"
}

# Validate that FILE is one of our archives and safe to unpack (no path traversal, expected members).
_backup_validate() {
    local f="$1" member
    [[ -f "$f" ]] || die "backup file not found: $f" "$HY2_EX_USAGE"
    tar -tzf "$f" >/dev/null 2>&1 || die "not a valid backup archive: $f" "$HY2_EX_USAGE"
    while IFS= read -r member; do
        case "$member" in
            /* | *..*) die "backup archive contains an unsafe path ($member); refusing" "$HY2_EX_USAGE" ;;
        esac
    done < <(tar -tzf "$f")
    tar -tzf "$f" | grep -qx './manifest.json' || tar -tzf "$f" | grep -qx 'manifest.json' || die "archive has no manifest.json; not a BlueSoftKeys backup" "$HY2_EX_USAGE"
}

# backup_restore FILE - replaces the panel DB (official importDB) and the wrapper state after explicit confirmation.
backup_restore() {
    local file="$1" work
    _backup_validate "$file"
    work="$(mktemp -d "$HY2_TMP/rs.XXXXXX")"
    tar -xzf "$file" -C "$work" --no-same-owner
    [[ -f "$work/x-ui.db" ]] || die "backup contains no x-ui.db" "$HY2_EX_USAGE"
    head -c 15 "$work/x-ui.db" | grep -q 'SQLite format 3' || die "x-ui.db in the backup is not a SQLite database" "$HY2_EX_USAGE"
    log_info "Backup: $(jq -r '"created \(.created_at), wrapper \(.wrapper_version), 3X-UI \(.panel_version)"' "$work/manifest.json")"
    printf '\nRestoring REPLACES the entire 3X-UI panel database (all inbounds, clients and settings, including ones\nnot managed by this wrapper) and this wrapper'"'"'s saved state with the contents of the backup.\n' >&2
    hy2_confirm "Continue with the restore?" n || die "restore cancelled" "$HY2_EX_GENERAL"

    local safety
    safety="$(backup_create pre-restore)"
    log_ok "Safety backup of the current state: $safety"

    api_upload /panel/api/server/importDB db "$work/x-ui.db" || die "the panel rejected the database import: ${API_MSG:-see panel log}. Your current data is unchanged; safety backup: $safety" "$HY2_EX_API"
    # restore wrapper state
    if [[ -d "$work/state" ]]; then
        state_dir_init
        cp -a "$work/state/." "$HY2_STATE_DIR/"
        chmod 700 "$HY2_STATE_DIR"
        find "$HY2_STATE_DIR" -maxdepth 1 -type f -exec chmod 600 {} +
    fi
    log_info "Waiting for the panel to restart..."
    sleep 4
    # the restored database brings its own settings and token hashes: re-resolve the URL and re-acquire a valid token
    local i ready=0
    for ((i = 0; i < 45; i++)); do
        if api_configure && api_acquire_token; then
            ready=1
            break
        fi
        sleep 2
    done
    ((ready)) || log_warn "no valid API token after the restore (the backup's tokens replace the current ones); run: sudo hysteria2 repair"
    state_load || true
    log_ok "Restore complete"
}
