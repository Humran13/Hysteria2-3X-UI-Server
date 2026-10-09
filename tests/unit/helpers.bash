# shellcheck shell=bash
# Shared helpers for the Bats unit tests. Everything runs inside $BATS_TEST_TMPDIR; no system paths are touched.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
export MOCK_TOKEN="mocktoken0123456789abcdef0123456789"
export MOCK_BASE="basepath1234"

hy2_test_env() {
    # BATS_TEST_TMPDIR is available in current Bats. Ubuntu 22.04 packages an
    # older release, so create an equally private per-test directory there.
    T="${BATS_TEST_TMPDIR:-}"
    if [[ -z "$T" ]]; then
        T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/hy2-bats.XXXXXX")"
    fi
    export HY2_TEST_MODE=1 HY2_SKIP_ROOT_CHECK=1 HY2_SKIP_SYSTEMD_CHECK=1 NO_COLOR=1 HY2_FORCE_NONINTERACTIVE=1
    export HY2_STATE_DIR="$T/state" HY2_LOG_DIR="$T/log" HY2_INSTALL_LOG="$T/3x-ui-install.log" HY2_BACKUP_DIR="$T/backup" HY2_LOCK_FILE="$T/lock"
    export HY2_HOME="$T/home" HY2_BIN_LINK="$T/bin/hysteria2" TMPDIR="$T/tmp"
    export XUI_MAIN_FOLDER="$T/xui" HY2_XUI_ETC="$T/xui-etc" MOCK_DIR="$T/mock"
    mkdir -p "$T"/{tmp,bin,shims,xui/bin,xui-etc,mock}
    export PATH="$T/shims:$PATH"
    install_shims
}

install_shims() {
    cat >"$T/shims/systemctl" <<'EOS'
#!/bin/bash
echo "$*" >>"$MOCK_DIR/systemctl.log"
case "$1" in
    is-active) [[ -f "$MOCK_DIR/svc_inactive" ]] && exit 3 || exit 0 ;;
    start) [[ -f "$MOCK_DIR/svc_start_fails" ]] && exit 1; rm -f "$MOCK_DIR/svc_inactive" ;;
    stop) touch "$MOCK_DIR/svc_inactive" ;;
esac
exit 0
EOS
    cat >"$T/shims/ss" <<'EOS'
#!/bin/bash
# fake ss: lists ports from $MOCK_DIR/listening ("port:procname:pid" per line)
port=""
for a in "$@"; do [[ "$a" =~ ^sport\ =\ :([0-9]+)$ ]] && port="${BASH_REMATCH[1]}"; done
{
    [[ -f "$MOCK_DIR/listening" ]] && cat "$MOCK_DIR/listening"
    # dynamic: every inbound known to the mock panel is "listening" (Xray) unless MOCK_XRAY_DOWN is set
    if [[ -n "${MOCK_PORT:-}" && ! -f "$MOCK_DIR/xray_down" ]]; then
        curl -s -m 2 "http://127.0.0.1:$MOCK_PORT/__state" 2>/dev/null | jq -r '.inbounds[]?.port | "\(.):xray:4242"' 2>/dev/null
    fi
} | while IFS=: read -r p name pid; do
    [[ -n "$p" ]] || continue
    [[ -n "$port" && "$p" != "$port" ]] && continue
    printf 'LISTEN 0      4096         *:%s         *:*    users:(("%s",pid=%s,fd=3))\n' "$p" "${name:-proc}" "${pid:-1}"
done
exit 0
EOS
    cat >"$T/shims/x-ui" <<'EOS'
#!/bin/bash
# fake /usr/bin/x-ui management script: only `uninstall` is needed
if [[ "$1" == "uninstall" ]]; then
    read -r ans
    [[ "$ans" == "y" ]] || exit 1
    rm -f "$XUI_MAIN_FOLDER/x-ui"; rm -rf "$HY2_XUI_ETC"; echo "Uninstalled Successfully."; exit 0
fi
exit 0
EOS
    cat >"$T/shims/ufw" <<'EOS'
#!/bin/bash
# fake ufw: state in $MOCK_DIR/ufw_rules ; active flag file ufw_active ; every call is logged
echo "$*" >>"$MOCK_DIR/ufw.log"
case "$1" in
    status)
        if [[ -f "$MOCK_DIR/ufw_active" ]]; then echo "Status: active"; echo; echo "To Action From"; echo "-- ------ ----"
            [[ -f "$MOCK_DIR/ufw_rules" ]] && while read -r r; do echo "$r                  ALLOW       Anywhere"; done <"$MOCK_DIR/ufw_rules"
        else echo "Status: inactive"; fi ;;
    allow) echo "$2" >>"$MOCK_DIR/ufw_rules" ;;
    --force) if [[ "$2" == "delete" ]]; then grep -vxF "$4" "$MOCK_DIR/ufw_rules" >"$MOCK_DIR/ufw_rules.new" || true; mv "$MOCK_DIR/ufw_rules.new" "$MOCK_DIR/ufw_rules"; fi ;;
esac
exit 0
EOS
    cat >"$T/xui/x-ui" <<'EOS'
#!/bin/bash
case "$1 ${2:-}" in
    "-v "*) echo "3.9.0" ;;
    "setting -show") echo "current panel settings as follows:"; echo "hasDefaultCredential: false"; echo "port: ${MOCK_PORT:-9999}"; echo "webBasePath: /${MOCK_BASE:-x}/" ;;
    "setting -getCert") echo "cert: "; echo "key: " ;;
    "setting -getApiToken") echo called >>"$MOCK_DIR/getApiToken.called"; echo "apiToken: SHOULD-NEVER-BE-CALLED" ;;
esac
exit 0
EOS
    chmod +x "$T"/shims/* "$T/xui/x-ui"
}

# Source the libraries exactly like bin/hysteria2 does.
load_libs() {
    export HY2_ROOT_DIR="$REPO" HY2_LIB_DIR="$REPO/lib"
    local m
    for m in common validate os network upstream api state hysteria firewall client output installer repair diagnostics backup update uninstall; do
        # shellcheck source=/dev/null
        . "$REPO/lib/$m.sh"
    done
    hy2_tmp_init
}

start_mock() {
    # Ask the kernel for an unused ephemeral port. Choosing from $RANDOM races
    # with services already running on shared CI hosts.
    MOCK_PORT=0
    export MOCK_PORT MOCK_BASE
    mkdir -p "$T/upstream"
    rm -f "$T/mock/ready"
    python3 "$REPO/tests/unit/mock_panel.py" "$MOCK_PORT" "$MOCK_BASE" "$MOCK_TOKEN" "$T/mock/ready" "$T/upstream" &
    MOCK_PID=$!
    local i
    for i in $(seq 1 50); do [[ -s "$T/mock/ready" ]] && break; sleep 0.1; done
    [[ -s "$T/mock/ready" ]] || return 1
    MOCK_PORT="$(cat "$T/mock/ready")"
    [[ "$MOCK_PORT" =~ ^[0-9]+$ ]] || return 1
    export MOCK_PORT
    export HY2_PANEL_URL="http://127.0.0.1:$MOCK_PORT/$MOCK_BASE"
    export HY2_UPSTREAM_WEB="http://127.0.0.1:$MOCK_PORT/web" HY2_UPSTREAM_RAW="http://127.0.0.1:$MOCK_PORT/raw" HY2_UPSTREAM_API="http://127.0.0.1:$MOCK_PORT/api"
    # Libraries may already have been loaded by setup(), so refresh their test-only endpoints too.
    UPSTREAM_WEB="$HY2_UPSTREAM_WEB" UPSTREAM_RAW="$HY2_UPSTREAM_RAW" UPSTREAM_API="$HY2_UPSTREAM_API"
}

stop_mock() { if [[ -n "${MOCK_PID:-}" ]]; then kill "$MOCK_PID" 2>/dev/null || true; fi; }

mock_ctl() { curl -s -X POST -d "$1" "http://127.0.0.1:$MOCK_PORT/__ctl" >/dev/null; }
mock_state() { curl -s "http://127.0.0.1:$MOCK_PORT/__state"; }

# A fake upstream release: install.sh creates the fake x-ui + install-result.env (as the real one does).
make_fake_upstream() { # tag
    mkdir -p "$T/upstream/$1"
    cat >"$T/upstream/$1/install.sh" <<'EOS'
#!/bin/bash
# fake MHSanaei/3x-ui installer (sha256 verification is mentioned so our sanity guard passes)
[[ "${XUI_NONINTERACTIVE:-}" == "1" ]] || { echo "not non-interactive" >&2; exit 9; }
[[ "${XUI_ENABLE_FAIL2BAN:-}" == "false" ]] || exit 9
[[ "${DEBIAN_FRONTEND:-}" == "noninteractive" ]] || { echo "debconf is interactive" >&2; exit 9; }
[[ "${DEBCONF_NONINTERACTIVE_SEEN:-}" == "true" ]] || exit 9
[[ "${NEEDRESTART_MODE:-}" == "a" ]] || { echo "needrestart is interactive" >&2; exit 9; }
[[ "${APT_LISTCHANGES_FRONTEND:-}" == "none" ]] || exit 9
[[ "${UCF_FORCE_CONFFOLD:-}" == "1" ]] || exit 9
[[ -r "${APT_CONFIG:-}" ]] && grep -q -- '--force-confold' "$APT_CONFIG" || { echo "missing apt conffile policy" >&2; exit 9; }
printf 'DEBIAN_FRONTEND=%s\nDEBCONF_NONINTERACTIVE_SEEN=%s\nNEEDRESTART_MODE=%s\nAPT_LISTCHANGES_FRONTEND=%s\nUCF_FORCE_CONFFOLD=%s\n' \
    "$DEBIAN_FRONTEND" "$DEBCONF_NONINTERACTIVE_SEEN" "$NEEDRESTART_MODE" "$APT_LISTCHANGES_FRONTEND" "$UCF_FORCE_CONFFOLD" \
    >"$MOCK_DIR/upstream-package-env"
[[ -z "${XUI_USERNAME:-}${XUI_PASSWORD:-}${XUI_PANEL_PORT:-}${XUI_WEB_BASE_PATH:-}" ]] || { echo "must not pin credentials" >&2; exit 9; }
echo "Username: admin-secret-user"; echo "Password: hunter2-secret-pass"; echo "API Token: leaked-token-value"
echo "OS detection: Ubuntu"; echo "Architecture detection: amd64"; echo "Downloading release asset: 50%"; echo "Checksum verification: OK"
echo "Extracting archive"; echo "Creating systemd service"; echo "Starting migrations"; echo "Installation completed"
[[ -n "${FAKE_INSTALL_FAIL:-}" ]] && exit 1
cp "$MOCK_DIR/../xui/x-ui.template" "$XUI_MAIN_FOLDER/x-ui" 2>/dev/null || true
touch "$XUI_MAIN_FOLDER/.installed"
[[ -n "${FAKE_NO_RESULT:-}" ]] && exit 0
umask 077
printf 'XUI_USERNAME=u\nXUI_PASSWORD=p\nXUI_PANEL_PORT=%s\nXUI_WEB_BASE_PATH=%s\nXUI_ACCESS_URL=http://x\nXUI_API_TOKEN=%s\nXUI_DB_TYPE=sqlite\n' "$MOCK_PORT" "$MOCK_BASE" "$MOCK_TOKEN" >"$HY2_XUI_ETC/install-result.env"
# sha256 sidecar verification would happen here in the real script
exit 0
EOS
}

# Sequence used by lifecycle tests: fake x-ui "not installed" until the fake installer ran.
prepare_uninstalled_panel() {
    cp "$T/xui/x-ui" "$T/xui/x-ui.template"
    rm -f "$T/xui/x-ui"
    make_fake_upstream v3.9.0
}
