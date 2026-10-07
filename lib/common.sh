#!/usr/bin/env bash
# shellcheck shell=bash
# common.sh - constants, logging, prompts, temp files, locking.
# Sourced by bin/hysteria2 (which sets `set -Eeuo pipefail`).

HY2_LIB_DIR="${HY2_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
HY2_ROOT_DIR="${HY2_ROOT_DIR:-$(dirname "$HY2_LIB_DIR")}"
HY2_VERSION="$(tr -d '[:space:]' <"$HY2_ROOT_DIR/VERSION" 2>/dev/null || true)"
HY2_VERSION="${HY2_VERSION:-unknown}"

HY2_PRODUCT="BlueSoftKeys Hysteria2 + 3X-UI Server"
HY2_REPO="${HY2_REPO:-Humran13/Hysteria2-3X-UI-Server}"
HY2_HOME="${HY2_HOME:-/opt/hysteria2-3x-ui-server}"
HY2_STATE_DIR="${HY2_STATE_DIR:-/etc/hysteria2-3x-ui-server}"
HY2_BACKUP_DIR="${HY2_BACKUP_DIR:-/var/backups/hysteria2-3x-ui-server}"
HY2_LOG_DIR="${HY2_LOG_DIR:-/var/log/hysteria2-3x-ui-server}"
HY2_BIN_LINK="${HY2_BIN_LINK:-/usr/local/bin/hysteria2}"
HY2_LOCK_FILE="${HY2_LOCK_FILE:-/run/lock/hysteria2-3x-ui-server.lock}"

# Exit codes
HY2_EX_GENERAL=1 HY2_EX_USAGE=2 HY2_EX_ENV=3 HY2_EX_UPSTREAM=4 HY2_EX_API=5 HY2_EX_STATE=6

HY2_VERBOSE="${HY2_VERBOSE:-0}"
HY2_INTERACTIVE=0
HY2_IN_FD=0
HY2_ASSUME_YES=0
HY2_TMP=""
HY2_SECRETS=()

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[0;31m' C_GRN=$'\033[0;32m' C_YEL=$'\033[0;33m' C_BLU=$'\033[0;34m' C_BOLD=$'\033[1m' C_OFF=$'\033[0m'
else
    C_RED="" C_GRN="" C_YEL="" C_BLU="" C_BOLD="" C_OFF=""
fi

# ---------- secrets & logging ----------

# Register a value that must never appear in logs/output produced by log_*.
hy2_secret_add() {
    local s="${1:-}"
    ((${#s} >= 6)) || return 0
    HY2_SECRETS+=("$s")
}

hy2_redact() {
    local msg="$1" s
    for s in "${HY2_SECRETS[@]}"; do
        msg="${msg//"$s"/<redacted>}"
    done
    printf '%s' "$msg"
}

_hy2_logfile_write() {
    local line
    line="$(hy2_redact "$1")"
    [[ -n "${HY2_LOG_DIR:-}" ]] || return 0
    if [[ ! -d "$HY2_LOG_DIR" ]]; then
        (umask 077 && mkdir -p "$HY2_LOG_DIR") 2>/dev/null || return 0
    fi
    (umask 077 && printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >>"$HY2_LOG_DIR/hysteria2.log") 2>/dev/null || true
}

log_info() { printf '%s\n' "${C_BLU}[*]${C_OFF} $(hy2_redact "$*")" >&2; _hy2_logfile_write "INFO $*"; }
log_ok() { printf '%s\n' "${C_GRN}[+]${C_OFF} $(hy2_redact "$*")" >&2; _hy2_logfile_write "OK   $*"; }
log_warn() { printf '%s\n' "${C_YEL}[!]${C_OFF} $(hy2_redact "$*")" >&2; _hy2_logfile_write "WARN $*"; }
log_err() { printf '%s\n' "${C_RED}[x]${C_OFF} $(hy2_redact "$*")" >&2; _hy2_logfile_write "ERROR $*"; }
log_debug() {
    [[ "$HY2_VERBOSE" == "1" ]] || return 0
    printf '%s\n' "[debug] $(hy2_redact "$*")" >&2
    _hy2_logfile_write "DEBUG $*"
}
log_step() { printf '\n%s\n' "${C_BOLD}==> $(hy2_redact "$*")${C_OFF}" >&2; _hy2_logfile_write "STEP $*"; }

die() {
    local msg="$1" code="${2:-$HY2_EX_GENERAL}"
    log_err "$msg"
    exit "$code"
}

# ---------- temp files ----------

hy2_tmp_init() {
    [[ -n "$HY2_TMP" && -d "$HY2_TMP" ]] && return 0
    HY2_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hy2.XXXXXXXX")" || die "cannot create temporary directory" "$HY2_EX_ENV"
    chmod 700 "$HY2_TMP"
}

hy2_tmp_cleanup() {
    if [[ -n "$HY2_TMP" && -d "$HY2_TMP" && "$HY2_TMP" == */hy2.* ]]; then
        rm -rf -- "$HY2_TMP"
    fi
    HY2_TMP=""
}

# Create a private temp file inside HY2_TMP and print its path.
hy2_mktemp() {
    hy2_tmp_init
    mktemp "$HY2_TMP/${1:-f}.XXXXXX"
}

# ---------- locking ----------

hy2_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    local dir
    dir="$(dirname "$HY2_LOCK_FILE")"
    [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 0
    exec 9>"$HY2_LOCK_FILE" || return 0
    flock -n 9 || die "another hysteria2 process is already running (lock: $HY2_LOCK_FILE)" "$HY2_EX_STATE"
}

# ---------- interactivity ----------

# Decide whether we can prompt. Under `curl | bash`, stdin is a pipe: fall back to /dev/tty when usable.
hy2_detect_interactive() {
    if [[ "${HY2_FORCE_NONINTERACTIVE:-0}" == "1" ]]; then
        HY2_INTERACTIVE=0
        return 0
    fi
    if [[ -t 0 ]]; then
        HY2_INTERACTIVE=1
        HY2_IN_FD=0
    elif [[ -c /dev/tty && ( -t 1 || -t 2 ) ]]; then
        exec 3</dev/tty
        HY2_INTERACTIVE=1
        HY2_IN_FD=3
    else
        HY2_INTERACTIVE=0
    fi
}

# hy2_ask VAR "Question" "default"  -> sets VAR (default returned when non-interactive or empty answer)
hy2_ask() {
    local __var="$1" __prompt="$2" __def="${3:-}" __ans=""
    if ((HY2_INTERACTIVE)); then
        if [[ -n "$__def" ]]; then
            printf '%s [%s]: ' "$__prompt" "$__def" >&2
        else
            printf '%s: ' "$__prompt" >&2
        fi
        IFS= read -r -u "$HY2_IN_FD" __ans || __ans=""
    fi
    printf -v "$__var" '%s' "${__ans:-$__def}"
}

# hy2_confirm "Question" [default y|n]  -> 0 for yes
hy2_confirm() {
    local q="$1" def="${2:-n}" ans=""
    if ((HY2_ASSUME_YES)); then return 0; fi
    if ((!HY2_INTERACTIVE)); then
        [[ "$def" == "y" ]]
        return
    fi
    local hint="y/N"
    [[ "$def" == "y" ]] && hint="Y/n"
    printf '%s [%s]: ' "$q" "$hint" >&2
    IFS= read -r -u "$HY2_IN_FD" ans || ans=""
    ans="${ans:-$def}"
    [[ "$ans" == [yY] || "$ans" == [yY][eE][sS] ]]
}

# hy2_confirm_typed "Question" "WORD" -> requires typing WORD exactly (never satisfied by --yes alone in non-interactive
# unless HY2_ASSUME_YES was given explicitly).
hy2_confirm_typed() {
    local q="$1" word="$2" ans=""
    if ((HY2_ASSUME_YES)); then return 0; fi
    ((HY2_INTERACTIVE)) || return 1
    printf '%s\nType %s to continue: ' "$q" "$word" >&2
    IFS= read -r -u "$HY2_IN_FD" ans || ans=""
    [[ "$ans" == "$word" ]]
}

# ---------- misc helpers ----------

hy2_require_root() {
    [[ "${HY2_SKIP_ROOT_CHECK:-0}" == "1" ]] && return 0
    ((EUID == 0)) || die "this command must be run as root (try: sudo hysteria2 ...)" "$HY2_EX_ENV"
}

hy2_have() { command -v "$1" >/dev/null 2>&1; }

# curl with sane timeouts/retries. Works with curl >= 7.58 (Ubuntu 18.04): no --retry-all-errors / --fail-with-body.
hy2_curl() {
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time "${HY2_CURL_MAX_TIME:-180}" "$@"
}

# Atomically write stdin to a file with the given mode (default 600).
hy2_write_atomic() {
    local dest="$1" mode="${2:-600}" tmp
    tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").XXXXXX")" || return 1
    if cat >"$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$dest"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

hy2_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
hy2_now_stamp() { date -u +%Y%m%d-%H%M%S; }

# Percent-decode (no eval, no printf %b on user data beyond hex escapes).
hy2_urldecode() {
    local s="${1//+/ }" out=""
    while [[ "$s" =~ ^([^%]*)%([0-9A-Fa-f]{2})(.*)$ ]]; do
        # shellcheck disable=SC2059
        out+="${BASH_REMATCH[1]}$(printf "\\x${BASH_REMATCH[2]}")"
        s="${BASH_REMATCH[3]}"
    done
    printf '%s' "${out}${s}"
}

hy2_random_alnum() { # length
    local n="${1:-12}" out=""
    while ((${#out} < n)); do
        # tr gets SIGPIPE once head has enough bytes; that is expected, hence `|| true` under pipefail.
        out+="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c "$n" || true)"
    done
    printf '%s' "${out:0:n}"
}

hy2_random_hex() { # bytes
    local n="${1:-8}"
    if hy2_have openssl; then
        openssl rand -hex "$n"
    else
        LC_ALL=C od -An -N"$n" -tx1 /dev/urandom | tr -d ' \n'
    fi
}
