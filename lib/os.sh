#!/usr/bin/env bash
# shellcheck shell=bash
# os.sh - OS / architecture detection and support classification.
#
# Support levels (see docs/testing.md for the evidence behind each entry):
#   tested       - full lifecycle test passed for this Hysteria2 project
#   best-effort  - supported target, not yet live-validated for this project
#   unsupported  - refuse unless --allow-unsupported-os (and even then only apt+systemd distros can work)

OS_ID="" OS_VERSION_ID="" OS_CODENAME="" OS_PRETTY="" OS_ID_LIKE=""
OS_SUPPORT="unsupported" OS_REASON=""
ARCH=""

os_detect() {
    local f="${HY2_OS_RELEASE_FILE:-/etc/os-release}"
    [[ -r "$f" ]] || f=/usr/lib/os-release
    [[ -r "$f" ]] || die "cannot read /etc/os-release; unsupported system" "$HY2_EX_ENV"
    # os-release is a trusted root-owned file of KEY=value assignments; parse only what we need without sourcing.
    local line key val
    OS_ID="" OS_VERSION_ID="" OS_CODENAME="" OS_PRETTY="" OS_ID_LIKE=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        val="${val%\"}"
        val="${val#\"}"
        val="${val%\'}"
        val="${val#\'}"
        case "$key" in
            ID) OS_ID="$val" ;;
            VERSION_ID) OS_VERSION_ID="$val" ;;
            VERSION_CODENAME) OS_CODENAME="$val" ;;
            PRETTY_NAME) OS_PRETTY="$val" ;;
            ID_LIKE) OS_ID_LIKE="$val" ;;
        esac
    done <"$f"
    OS_ID="${OS_ID,,}"
    [[ -n "$OS_PRETTY" ]] || OS_PRETTY="$OS_ID $OS_VERSION_ID"
}

# Sets ARCH to amd64|arm64 or "unsupported:<uname -m>".
arch_detect() {
    local m="${HY2_UNAME_M:-$(uname -m)}"
    case "$m" in
        x86_64 | amd64 | x64) ARCH="amd64" ;;
        aarch64 | arm64 | armv8*) ARCH="arm64" ;;
        *) ARCH="unsupported:$m" ;;
    esac
}

# Compare dotted versions: returns 0 if $1 >= $2 (numeric, major.minor).
_ver_ge() {
    local a_major="${1%%.*}" a_minor="${1#*.}" b_major="${2%%.*}" b_minor="${2#*.}"
    [[ "$a_minor" == "$1" ]] && a_minor=0
    [[ "$b_minor" == "$2" ]] && b_minor=0
    a_minor="${a_minor%%.*}"
    b_minor="${b_minor%%.*}"
    if ((10#$a_major != 10#$b_major)); then
        ((10#$a_major > 10#$b_major))
        return
    fi
    ((10#$a_minor >= 10#$b_minor))
}

# Fills OS_SUPPORT / OS_REASON from OS_ID + OS_VERSION_ID.
os_classify() {
    OS_SUPPORT="unsupported"
    OS_REASON=""
    case "$OS_ID" in
        ubuntu)
            [[ "$OS_VERSION_ID" =~ ^[0-9]+\.[0-9]+$ ]] || {
                OS_REASON="unrecognised Ubuntu version '$OS_VERSION_ID'"
                return 0
            }
            case "$OS_VERSION_ID" in
                20.04)
                    OS_SUPPORT="best-effort"
                    OS_REASON="supported target but past standard support; use Ubuntu Pro/ESM and perform an external Hysteria2 smoke test"
                    ;;
                24.04) OS_SUPPORT="tested" ;;
                22.04 | 26.04)
                    OS_SUPPORT="best-effort"
                    OS_REASON="supported target; this release has not yet completed a recorded live Hysteria2 lifecycle in this repository"
                    ;;
                *)
                    if _ver_ge "$OS_VERSION_ID" "26.04"; then
                        OS_SUPPORT="best-effort"
                        OS_REASON="Ubuntu $OS_VERSION_ID is newer than the newest tested release (26.04)"
                    elif _ver_ge "$OS_VERSION_ID" "20.04"; then
                        OS_SUPPORT="best-effort"
                        OS_REASON="Ubuntu $OS_VERSION_ID is an interim/untested release"
                    else
                        OS_REASON="Ubuntu $OS_VERSION_ID is older than the minimum target 20.04"
                    fi
                    ;;
            esac
            ;;
        *)
            OS_REASON="'$OS_ID' is not Ubuntu (only Ubuntu 20.04/22.04/24.04/26.04 are supported targets)"
            ;;
    esac
}

# Full environment gate used by `install`. Honors OPT_ALLOW_UNSUPPORTED_OS.
os_check_all() {
    os_detect
    arch_detect
    os_classify

    if [[ "$ARCH" == unsupported:* ]]; then
        die "unsupported CPU architecture '${ARCH#unsupported:}'. Supported: amd64 (x86_64), arm64 (aarch64)." "$HY2_EX_ENV"
    fi

    case "$OS_SUPPORT" in
        tested) log_ok "OS: $OS_PRETTY ($ARCH) - tested" ;;
        best-effort) log_warn "OS: $OS_PRETTY ($ARCH) - best-effort: $OS_REASON" ;;
        *)
            if [[ "${OPT_ALLOW_UNSUPPORTED_OS:-0}" == "1" ]]; then
                log_warn "OS: $OS_PRETTY ($ARCH) - UNSUPPORTED ($OS_REASON); continuing because --allow-unsupported-os was given"
            else
                die "unsupported OS: $OS_PRETTY. $OS_REASON. Re-run with --allow-unsupported-os to try anyway." "$HY2_EX_ENV"
            fi
            ;;
    esac

    if [[ ! -d /run/systemd/system && "${HY2_SKIP_SYSTEMD_CHECK:-0}" != "1" ]]; then
        die "systemd is not running as init (PID 1). 3X-UI is installed as a systemd service; containers without systemd are not supported." "$HY2_EX_ENV"
    fi
    hy2_have apt-get || die "apt-get not found; only apt-based systems are implemented" "$HY2_EX_ENV"
}

# Install packages we depend on (official OS repositories only). Idempotent.
os_install_deps() {
    local missing=() cmd
    local -A pkg_for=([curl]=curl [jq]=jq [openssl]=openssl [ss]=iproute2 [flock]=util-linux [tar]=tar [sha256sum]=coreutils)
    for cmd in curl jq openssl ss flock tar sha256sum; do
        hy2_have "$cmd" || missing+=("${pkg_for[$cmd]}")
    done
    [[ -d /etc/ssl/certs ]] || missing+=(ca-certificates)
    if ((${#missing[@]} == 0)); then
        log_debug "all dependencies already present"
        return 0
    fi
    log_info "Installing dependencies from the OS repositories: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    hy2_run_logged apt-get update -q || log_warn "apt-get update reported problems; trying to continue"
    hy2_run_logged apt-get install -y -q --no-install-recommends "${missing[@]}" || die "failed to install dependencies: ${missing[*]}" "$HY2_EX_ENV"
}

# Run a command; on failure show the tail of its output. Output is kept out of the terminal unless --verbose.
hy2_run_logged() {
    local out rc=0
    out="$(hy2_mktemp run)"
    if [[ "$HY2_VERBOSE" == "1" ]]; then
        "$@" 2>&1 | tee "$out" >&2 || rc=${PIPESTATUS[0]}
    else
        "$@" >"$out" 2>&1 || rc=$?
    fi
    if ((rc != 0)); then
        log_err "command failed (exit $rc): $*"
        tail -n 15 "$out" | while IFS= read -r l; do log_err "  $(hy2_redact "$l")"; done
    fi
    rm -f "$out"
    return "$rc"
}
