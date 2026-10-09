#!/usr/bin/env bats

load helpers

setup() {
    hy2_test_env
    load_libs
}

teardown() {
    stop_mock
    hy2_tmp_cleanup
}

make_streaming_installer() {
    STREAM_SCRIPT="$T/stream-installer.sh"
    cat >"$STREAM_SCRIPT" <<'EOS'
#!/bin/bash
[[ "${XUI_NONINTERACTIVE:-}" == "1" ]] || exit 90
if IFS= read -r -t 0.1 unexpected; then
    echo "stdin unexpectedly available: $unexpected"
    exit 91
fi
echo "non-interactive mode enabled"
echo "stdin is disconnected"
echo "OS detection: Ubuntu 24.04"
printf 'GitHub download started\r'
[[ -n "${STREAM_HOLD:-}" ]] && sleep "$STREAM_HOLD"
echo "Architecture detection: amd64"
echo "Installing packages"
printf 'GitHub download: 50%%\rGitHub download: 100%%\n'
echo "Password: generated-password-must-not-leak"
echo "API Token=generated-token-must-not-leak"
echo "Database: postgres://dbuser:db-password-must-not-leak@example/db"
echo "Checksum verification: OK"
echo "Extracting archive"
echo "Creating and starting systemd service"
echo "Running migrations"
echo "Installation completed"
exit "${STREAM_EXIT:-0}"
EOS
    chmod +x "$STREAM_SCRIPT"
}

@test "upstream output is live by default, non-interactive, filtered, and logged" {
    make_streaming_installer
    UPSTREAM_SCRIPT_ARGS=()

    run _upstream_run_script "$STREAM_SCRIPT" env XUI_NONINTERACTIVE=1

    [ "$status" -eq 0 ]
    [[ "$output" == *"non-interactive mode enabled"* ]]
    [[ "$output" == *"stdin is disconnected"* ]]
    [[ "$output" == *"OS detection: Ubuntu 24.04"* ]]
    [[ "$output" == *"GitHub download: 50%"* ]]
    [[ "$output" == *"Checksum verification: OK"* ]]
    [[ "$output" == *"Running migrations"* ]]
    [[ "$output" == *"Password: <redacted>"* ]]
    [[ "$output" == *"API Token= <redacted>"* ]]
    [[ "$output" != *"generated-password-must-not-leak"* ]]
    [[ "$output" != *"generated-token-must-not-leak"* ]]
    [[ "$output" != *"db-password-must-not-leak"* ]]
    grep -q 'OS detection: Ubuntu 24.04' "$HY2_INSTALL_LOG"
    grep -q 'GitHub download: 100%' "$HY2_INSTALL_LOG"
    ! grep -q 'must-not-leak' "$HY2_INSTALL_LOG"
    [ "$(stat -c '%a' "$HY2_INSTALL_LOG")" = "600" ]
}

@test "first installer lines are visible before the upstream process exits" {
    make_streaming_installer
    UPSTREAM_SCRIPT_ARGS=()
    capture="$T/live-output"

    _upstream_run_script "$STREAM_SCRIPT" env XUI_NONINTERACTIVE=1 STREAM_HOLD=2 >"$capture" 2>&1 &
    installer_pid=$!
    seen=0
    for _ in $(seq 1 10); do
        if grep -q 'GitHub download started' "$capture" 2>/dev/null && kill -0 "$installer_pid" 2>/dev/null; then
            seen=1
            break
        fi
        sleep 0.1
    done
    wait "$installer_pid"

    [ "$seen" -eq 1 ]
}

@test "upstream exit status survives the streaming pipeline" {
    make_streaming_installer
    UPSTREAM_SCRIPT_ARGS=()

    run env STREAM_EXIT=37 bash -c 'source "$1/lib/common.sh"; source "$1/lib/upstream.sh"; hy2_tmp_init; UPSTREAM_SCRIPT_ARGS=(); _upstream_run_script "$2" env XUI_NONINTERACTIVE=1' _ "$REPO" "$STREAM_SCRIPT"

    [ "$status" -eq 37 ]
    [[ "$output" == *"upstream script failed (exit 37)"* ]]
    [[ "$output" == *"Installation completed"* ]]
    grep -q 'failed with exit 37' "$HY2_INSTALL_LOG"
}

@test "upstream watchdog warns after an output stall without killing the installer" {
    make_streaming_installer
    UPSTREAM_SCRIPT_ARGS=()
    HY2_UPSTREAM_STALL_WARN_SECONDS=1

    run _upstream_run_script "$STREAM_SCRIPT" env XUI_NONINTERACTIVE=1 STREAM_HOLD=2

    [ "$status" -eq 0 ]
    [[ "$output" == *"No upstream output for 1s"* ]]
    [[ "$output" == *"Installation completed"* ]]
}

@test "failed GitHub connectivity stops before installer launch with a useful error" {
    ARCH=amd64
    UPSTREAM_WEB="http://127.0.0.1:1"
    UPSTREAM_RAW="http://127.0.0.1:1"
    HY2_PREFLIGHT_CONNECT_TIMEOUT=1
    HY2_PREFLIGHT_MAX_TIME=1

    run upstream_preflight v3.9.0

    [ "$status" -ne 0 ]
    [[ "$output" == *"GitHub connectivity check failed"* ]]
    [[ "$output" == *"official installer was not started"* ]]
}

@test "normal non-interactive installation completes with live safe output" {
    start_mock
    prepare_uninstalled_panel
    ARCH=amd64

    run upstream_install v3.9.0

    [ "$status" -eq 0 ]
    [ -x "$UPSTREAM_DIR/x-ui" ]
    [[ "$output" == *"Live installation output follows"* ]]
    [[ "$output" == *"OS detection: Ubuntu"* ]]
    [[ "$output" == *"Installation completed"* ]]
    [[ "$output" != *"hunter2-secret-pass"* ]]
    [[ "$output" != *"leaked-token-value"* ]]
    [[ "$output" != *"awk: option"* ]]
    grep -q 'Checksum verification: OK' "$HY2_INSTALL_LOG"
}

@test "Ubuntu upstream package environment disables needrestart and debconf prompts" {
    start_mock
    prepare_uninstalled_panel
    ARCH=amd64

    run upstream_install v3.9.0

    [ "$status" -eq 0 ]
    grep -qx 'DEBIAN_FRONTEND=noninteractive' "$MOCK_DIR/upstream-package-env"
    grep -qx 'DEBCONF_NONINTERACTIVE_SEEN=true' "$MOCK_DIR/upstream-package-env"
    grep -qx 'NEEDRESTART_MODE=a' "$MOCK_DIR/upstream-package-env"
    grep -qx 'APT_LISTCHANGES_FRONTEND=none' "$MOCK_DIR/upstream-package-env"
    grep -qx 'UCF_FORCE_CONFFOLD=1' "$MOCK_DIR/upstream-package-env"
}

@test "pending installed kernel warns but does not block installation" {
    mkdir -p "$T/boot"
    touch "$T/boot/vmlinuz-6.8.0-139-generic" "$T/boot/vmlinuz-6.8.0-146-generic"
    HY2_BOOT_DIR="$T/boot"
    HY2_UNAME_R="6.8.0-139-generic"

    run os_warn_pending_kernel

    [ "$status" -eq 0 ]
    [[ "$output" == *"newer kernel is installed"* ]]
    [[ "$output" == *"Continuing unattended; no keyboard input will be required"* ]]
    [[ "$output" == *"Reboot the VPS after installation"* ]]
}
