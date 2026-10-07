#!/usr/bin/env bash
# shellcheck shell=bash
# validate.sh - strict input validators. Every function returns 0 (valid) / 1 (invalid) and prints nothing.
# All user-supplied values that reach JSON, URLs, shell or the panel API pass through these first.

valid_port() {
    [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] || return 1
    local p=$((10#$1))
    ((p >= 1 && p <= 65535))
}

valid_ipv4() {
    local ip="${1:-}" o
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local IFS=.
    for o in $ip; do
        ((10#$o <= 255)) || return 1
    done
}

# RFC 1123 hostname (labels 1-63 chars, total <= 253), must contain at least one dot unless "localhost"-like single label allowed.
valid_hostname() {
    local h="${1:-}"
    ((${#h} >= 1 && ${#h} <= 253)) || return 1
    [[ "$h" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]] || return 1
    # an all-numeric dotted string is an IP, not a hostname
    [[ "$h" =~ ^[0-9.]+$ ]] && return 1
    return 0
}

# Address clients connect to: IPv4 or DNS name.
valid_server_address() {
    valid_ipv4 "$1" || valid_hostname "$1"
}

# SNI must be a DNS hostname with a dot (IP literals are not valid SNI values).
valid_sni() {
    valid_hostname "${1:-}" && [[ "$1" == *.* ]]
}

# Client display name / panel email. Conservative: starts alnum, then [A-Za-z0-9._-], max 64.
valid_client_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

# Stable upstream tag: vMAJOR.MINOR.PATCH only (rejects dev-latest, dev, pre-release suffixes).
valid_stable_tag() {
    [[ "${1:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

valid_positive_int() {
    [[ "${1:-}" =~ ^[1-9][0-9]{0,8}$ ]]
}

valid_nonneg_int() {
    [[ "${1:-}" =~ ^(0|[1-9][0-9]{0,8})$ ]]
}
