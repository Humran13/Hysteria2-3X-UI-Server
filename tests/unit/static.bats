#!/usr/bin/env bats

@test "all shipped shell files pass bash syntax" {
    while IFS= read -r f; do bash -n "$f" || return 1; done < <(find bin lib tests tools -type f \( -name '*.sh' -o -path 'bin/hysteria2' \))
    bash -n install.sh
}

@test "obsolete protocol implementation terms are absent" {
    run bash -c "grep -ERni --exclude=mock_panel.py --exclude=static.bats 'vless|reality|short.?id|x25519|mode_(tcp|grpc|xhttp)' README.md docs bin lib tests"
    [ "$status" -eq 1 ]
}

@test "generic defaults and UDP behavior are documented" {
    grep -q 'INBOUND_REMARK="Hysteria2"' lib/hysteria.sh
    grep -q 'DEFAULT_CLIENT_NAME="client1"' lib/hysteria.sh
    grep -q 'ufw allow "${port}/udp"' lib/firewall.sh
    grep -q 'ss -H -lun' lib/network.sh
}

@test "bootstrap manifest names every installed runtime file" {
    while IFS= read -r f; do grep -q "  $f$" SHA256SUMS || { echo "missing $f"; return 1; }; done < <(printf '%s\n' bin/hysteria2 VERSION; find lib -maxdepth 1 -type f -name '*.sh' | sort)
}
