#!/usr/bin/env bash
# shellcheck shell=bash
# upstream.sh - everything that touches the official MHSanaei/3x-ui project: stable discovery, unattended install,
# update, uninstall, panel settings discovery. We only ever run upstream's own scripts (fetched from the pinned
# release tag) - upstream keeps verifying release checksums itself.

UPSTREAM_REPO="MHSanaei/3x-ui"
# Newest upstream stable this wrapper was validated against (see docs/testing.md).
TESTED_UPSTREAM="v3.9.0"

UPSTREAM_WEB="https://github.com/${UPSTREAM_REPO}"
UPSTREAM_RAW="https://raw.githubusercontent.com/${UPSTREAM_REPO}"
UPSTREAM_API="https://api.github.com/repos/${UPSTREAM_REPO}"
# Source overrides exist for the automated test-suite only; they are ignored otherwise so nobody can be pointed at a mirror.
if [[ "${HY2_TEST_MODE:-0}" == "1" ]]; then
    UPSTREAM_WEB="${HY2_UPSTREAM_WEB:-$UPSTREAM_WEB}"
    UPSTREAM_RAW="${HY2_UPSTREAM_RAW:-$UPSTREAM_RAW}"
    UPSTREAM_API="${HY2_UPSTREAM_API:-$UPSTREAM_API}"
fi

UPSTREAM_DIR="${XUI_MAIN_FOLDER:-/usr/local/x-ui}"
UPSTREAM_ETC="${HY2_XUI_ETC:-/etc/x-ui}"
UPSTREAM_RESULT_FILE="${HY2_XUI_RESULT_FILE:-$UPSTREAM_ETC/install-result.env}"
UPSTREAM_SERVICE="x-ui"

# Filled by upstream_result_load
XUI_USERNAME="" XUI_PASSWORD="" XUI_PANEL_PORT="" XUI_WEB_BASE_PATH="" XUI_API_TOKEN=""
# Filled by upstream_panel_settings
PANEL_PORT="" PANEL_BASE_PATH="" PANEL_CERT=""

upstream_installed() {
    [[ -x "$UPSTREAM_DIR/x-ui" ]]
}

upstream_service_active() {
    systemctl is-active --quiet "$UPSTREAM_SERVICE" 2>/dev/null
}

upstream_version() {
    upstream_installed || return 1
    local v
    v="$("$UPSTREAM_DIR/x-ui" -v 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
    [[ -n "$v" ]] || return 1
    [[ "$v" == v* ]] || v="v$v"
    printf '%s' "$v"
}

upstream_xray_version() {
    local bin
    bin="$(find "$UPSTREAM_DIR/bin" -maxdepth 1 -name 'xray-linux-*' 2>/dev/null | head -n1 || true)"
    [[ -x "$bin" ]] || return 1
    "$bin" version 2>/dev/null | awk 'NR==1{print $2}'
}

# Latest STABLE tag (vX.Y.Z). Never returns dev-latest / pre-releases.
upstream_latest_stable() {
    local url tag json
    url="$(curl -sSLI -o /dev/null -w '%{url_effective}' --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 60 "${UPSTREAM_WEB}/releases/latest" 2>/dev/null || true)"
    tag="${url##*/tag/}"
    if [[ "$tag" != "$url" ]] && valid_stable_tag "$tag"; then
        printf '%s' "$tag"
        return 0
    fi
    json="$(hy2_curl "${UPSTREAM_API}/releases/latest" 2>/dev/null || true)"
    tag="$(printf '%s' "$json" | jq -r 'select((.prerelease // false) == false and (.draft // false) == false) | .tag_name // empty' 2>/dev/null || true)"
    if valid_stable_tag "$tag"; then
        printf '%s' "$tag"
        return 0
    fi
    return 1
}

# Download an upstream helper script from a release tag into a private temp file; print its path.
# Refuses anything that does not look like the official script.
upstream_fetch_script() {
    local name="$1" tag="$2" dest
    valid_stable_tag "$tag" || die "refusing to fetch upstream script for non-stable ref '$tag'" "$HY2_EX_UPSTREAM"
    dest="$(hy2_mktemp "upstream-$name")"
    hy2_curl "${UPSTREAM_RAW}/${tag}/${name}" -o "$dest" || {
        log_err "failed to download upstream ${name} for ${tag}"
        return 1
    }
    [[ -s "$dest" ]] || {
        log_err "downloaded upstream ${name} is empty"
        return 1
    }
    head -n1 "$dest" | grep -q '^#!.*bash' || {
        log_err "upstream ${name} does not look like a bash script"
        return 1
    }
    grep -q 'MHSanaei/3x-ui' "$dest" || {
        log_err "upstream ${name} does not reference MHSanaei/3x-ui"
        return 1
    }
    # Defensive: our security model relies on upstream verifying release checksums.
    if [[ "$name" == "install.sh" || "$name" == "update.sh" ]]; then
        grep -q 'sha256' "$dest" || {
            log_err "upstream ${name} no longer verifies release checksums; refusing (wrapper needs review)"
            return 1
        }
    fi
    printf '%s' "$dest"
}

# Run an upstream script with all output captured (it prints credentials!). Show only a filtered tail on failure.
_upstream_run_script() {
    local script="$1"
    shift
    local out rc=0
    out="$(hy2_mktemp upstream-out)"
    if [[ "$HY2_VERBOSE" == "1" ]]; then
        "$@" bash "$script" "${UPSTREAM_SCRIPT_ARGS[@]}" </dev/null 2>&1 | _upstream_filter | tee "$out" >&2 || rc=${PIPESTATUS[0]}
    else
        "$@" bash "$script" "${UPSTREAM_SCRIPT_ARGS[@]}" </dev/null >"$out" 2>&1 || rc=$?
    fi
    if ((rc != 0)); then
        log_err "upstream script failed (exit $rc). Last output (credentials filtered):"
        _upstream_filter <"$out" | tail -n 25 | while IFS= read -r l; do log_err "  $l"; done
    fi
    rm -f "$out"
    return "$rc"
}

# Strip colour codes and any line that could carry credentials.
_upstream_filter() {
    sed -E 's/\x1b\[[0-9;]*m//g' | grep -Eiv 'username|password|api ?token|access url|webbasepath|credentials|dsn' || true
}

# upstream_install TAG  - unattended install of the pinned STABLE tag via the official installer.
upstream_install() {
    local tag="$1" script
    valid_stable_tag "$tag" || die "refusing to install non-stable upstream ref '$tag'" "$HY2_EX_UPSTREAM"
    script="$(upstream_fetch_script install.sh "$tag")" || return 1
    log_info "Running the official 3X-UI installer ($tag) unattended; this can take a minute..."
    UPSTREAM_SCRIPT_ARGS=("$tag")
    # Random username/password/port/base-path/API token are generated by upstream (we deliberately set none of them).
    _upstream_run_script "$script" env XUI_NONINTERACTIVE=1 XUI_ENABLE_FAIL2BAN=false || return 1
    upstream_installed || {
        log_err "upstream installer finished but $UPSTREAM_DIR/x-ui is missing"
        return 1
    }
    return 0
}

# upstream_update TAG - official update.sh for a specific STABLE tag (data preserved by upstream).
upstream_update() {
    local tag="$1" script
    valid_stable_tag "$tag" || die "refusing to update to non-stable upstream ref '$tag'" "$HY2_EX_UPSTREAM"
    script="$(upstream_fetch_script update.sh "$tag")" || return 1
    log_info "Running the official 3X-UI updater ($tag)..."
    UPSTREAM_SCRIPT_ARGS=()
    _upstream_run_script "$script" env XUI_NONINTERACTIVE=1 XUI_UPDATE_TAG="$tag" XUI_ENABLE_FAIL2BAN=false
}

# A line of install-result.env is only evaluated if, once every legitimate `printf %q` construct (backslash escapes,
# '...' and $'...' quoting) is removed, nothing that could start a command/expansion remains.
_env_line_is_safe() {
    local line="$1" rest
    [[ "$line" =~ ^[A-Z_][A-Z0-9_]*= ]] || return 1
    rest="${line#*=}"
    rest="$(printf '%s' "$rest" | sed -E "s/\\\\.//g; s/\\\$'([^'\\\\]|\\\\.)*'//g; s/'[^']*'//g")"
    [[ "$rest" =~ [\$\`\;\&\|\(\)\<\>\{\}\*\?\!\ ] ]] && return 1
    return 0
}

# Parse /etc/x-ui/install-result.env WITHOUT trusting it blindly: it must be root-owned and not group/world accessible;
# every line must be a plain KEY=value assignment (checked above) before the file is evaluated in a subshell, and every
# field is validated before use.
upstream_result_load() {
    local f="$UPSTREAM_RESULT_FILE" owner mode fields line
    XUI_USERNAME="" XUI_PASSWORD="" XUI_PANEL_PORT="" XUI_WEB_BASE_PATH="" XUI_API_TOKEN=""
    [[ -f "$f" ]] || return 1
    owner="$(stat -c '%u' "$f" 2>/dev/null || echo x)"
    mode="$(stat -c '%a' "$f" 2>/dev/null || echo 777)"
    if [[ "${HY2_TEST_MODE:-0}" != "1" ]]; then
        [[ "$owner" == "0" ]] || {
            log_warn "$f is not owned by root; ignoring it"
            return 1
        }
    fi
    ((8#$mode & 8#077)) && {
        log_warn "$f has unsafe permissions ($mode); ignoring it"
        return 1
    }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        _env_line_is_safe "$line" || {
            log_warn "$f contains an unexpected construct; ignoring it"
            return 1
        }
    done <"$f"
    # shellcheck disable=SC1090
    fields="$(
        set +eu
        # shellcheck disable=SC1090
        . "$f" >/dev/null 2>&1 || exit 1
        printf '%s\n%s\n%s\n%s\n%s\n' "${XUI_USERNAME:-}" "${XUI_PASSWORD:-}" "${XUI_PANEL_PORT:-}" "${XUI_WEB_BASE_PATH:-}" "${XUI_API_TOKEN:-}"
    )" || {
        log_warn "$f is malformed"
        return 1
    }
    {
        IFS= read -r XUI_USERNAME
        IFS= read -r XUI_PASSWORD
        IFS= read -r XUI_PANEL_PORT
        IFS= read -r XUI_WEB_BASE_PATH
        IFS= read -r XUI_API_TOKEN
    } <<<"$fields"
    valid_port "$XUI_PANEL_PORT" || {
        log_warn "$f: invalid panel port"
        return 1
    }
    [[ "$XUI_WEB_BASE_PATH" =~ ^[A-Za-z0-9_-]{4,64}$ ]] || {
        log_warn "$f: invalid web base path"
        return 1
    }
    [[ "$XUI_API_TOKEN" =~ ^[A-Za-z0-9_.-]{16,256}$ ]] || {
        log_warn "$f: missing or invalid API token"
        return 1
    }
    hy2_secret_add "$XUI_PASSWORD"
    hy2_secret_add "$XUI_API_TOKEN"
    return 0
}

# Read (non-secret) panel settings from the official CLI. `setting -show` is read-only.
# NEVER call `setting -getApiToken` here: it regenerates (and invalidates) the token.
upstream_panel_settings() {
    upstream_installed || return 1
    local out
    out="$("$UPSTREAM_DIR/x-ui" setting -show 2>/dev/null || true)"
    PANEL_PORT="$(printf '%s\n' "$out" | sed -n 's/^port: *//p' | head -n1 | tr -d '[:space:]')"
    PANEL_BASE_PATH="$(printf '%s\n' "$out" | sed -n 's/^webBasePath: *//p' | head -n1 | tr -d '[:space:]')"
    PANEL_BASE_PATH="${PANEL_BASE_PATH#/}"
    PANEL_BASE_PATH="${PANEL_BASE_PATH%/}"
    PANEL_CERT="$("$UPSTREAM_DIR/x-ui" setting -getCert 2>/dev/null | sed -n 's/^cert: *//p' | head -n1 | tr -d '[:space:]' || true)"
    valid_port "$PANEL_PORT" || return 1
    return 0
}

# Official uninstall: the `x-ui` management script (x-ui.sh) asks y/n on stdin.
upstream_uninstall() {
    upstream_installed || return 0
    log_info "Running the official 3X-UI uninstaller..."
    local out script
    script="$(command -v x-ui 2>/dev/null || true)"
    [[ -n "$script" ]] || script="$UPSTREAM_DIR/x-ui.sh"
    [[ -f "$script" ]] || {
        log_err "cannot find the official x-ui management script"
        return 1
    }
    out="$(hy2_mktemp xui-uninstall)"
    # XUI_MAIN_FOLDER: x-ui.sh assumes the Docker image layout (/app) when /.dockerenv exists; be explicit.
    # The upstream script deletes itself at the end and may exit non-zero even on success: judge by the result instead.
    printf 'y\n' | env XUI_MAIN_FOLDER="$UPSTREAM_DIR" bash "$script" uninstall >"$out" 2>&1 || true
    if [[ -x "$UPSTREAM_DIR/x-ui" ]] || grep -q 'Please install the panel first' "$out"; then
        log_err "official uninstall failed"
        _upstream_filter <"$out" | tail -n 15 | while IFS= read -r l; do log_err "  $l"; done
        return 1
    fi
    rm -f "$out"
    return 0
}
