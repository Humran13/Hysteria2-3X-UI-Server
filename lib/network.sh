#!/usr/bin/env bash
# shellcheck shell=bash
# network.sh - port / address / reachability helpers. Read-only: never stops or reconfigures anything.

# Print process descriptions of UDP listeners on PORT (empty if none).
net_port_listeners() {
    local port="$1" out
    out="$(ss -H -lunp "sport = :${port}" 2>/dev/null || true)"
    [[ -n "$out" ]] || return 0
    # users:(("nginx",pid=812,fd=6),...) -> nginx(812)
    printf '%s\n' "$out" | grep -o 'users:.*' | grep -o '("[^"]*",pid=[0-9]*' | sed -E 's/\("([^"]*)",pid=([0-9]*)/\1(\2)/' | sort -u | paste -sd, - || true
    if ! printf '%s\n' "$out" | grep -q 'users:'; then
        echo "unknown process"
    fi
}

net_port_in_use() {
    local port="$1"
    [[ -n "$(ss -H -lun "sport = :${port}" 2>/dev/null || true)" ]]
}

net_port_listening() { net_port_in_use "$@"; }

net_is_private_ipv4() {
    local ip="$1" a b
    valid_ipv4 "$ip" || return 1
    IFS=. read -r a b _ _ <<<"$ip"
    ((10#$a == 10)) && return 0
    ((10#$a == 127)) && return 0
    ((10#$a == 0)) && return 0
    ((10#$a == 169 && 10#$b == 254)) && return 0
    ((10#$a == 172 && 10#$b >= 16 && 10#$b <= 31)) && return 0
    ((10#$a == 192 && 10#$b == 168)) && return 0
    ((10#$a == 100 && 10#$b >= 64 && 10#$b <= 127)) && return 0
    return 1
}

# Best-effort public IPv4: routable local address first, else a TLS-verified IP echo service.
net_detect_public_ip() {
    local ip="" url
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    if valid_ipv4 "$ip" && ! net_is_private_ipv4 "$ip"; then
        printf '%s' "$ip"
        return 0
    fi
    for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
        ip="$(curl -fsS --connect-timeout 5 --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
        if valid_ipv4 "$ip"; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

# Resolve a hostname to its first IPv4 (empty on failure).
net_resolve_ipv4() {
    getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}' || true
}
