#!/usr/bin/env bash
# shellcheck shell=bash
# Native Xray/3X-UI Hysteria2 configuration and share-link validation.

INBOUND_REMARK="Hysteria2"
DEFAULT_CLIENT_NAME="client1"
TLS_MODE="" TLS_CERT="" TLS_KEY="" TLS_SNI="" TLS_PIN=""

hysteria_cert_pin() {
    openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null |
        sed -E 's/^.*=//; s/://g' | tr '[:upper:]' '[:lower:]'
}

hysteria_validate_cert_key() {
    local cert="$1" key="$2" cpub kpub
    [[ -r "$cert" && -r "$key" ]] || return 1
    openssl x509 -in "$cert" -noout >/dev/null 2>&1 || return 1
    openssl pkey -in "$key" -noout >/dev/null 2>&1 || return 1
    cpub="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | sha256sum | awk '{print $1}')"
    kpub="$(openssl pkey -in "$key" -pubout -outform der 2>/dev/null | sha256sum | awk '{print $1}')"
    [[ -n "$cpub" && "$cpub" == "$kpub" ]]
}

hysteria_prepare_tls() {
    local dir="$HY2_STATE_DIR/tls" san
    mkdir -p "$dir"
    chmod 700 "$dir"
    TLS_SNI="${OPT_SNI:-$SERVER_ADDR}"
    if [[ -n "${OPT_TLS_CERT:-}" || -n "${OPT_TLS_KEY:-}" ]]; then
        [[ -n "${OPT_TLS_CERT:-}" && -n "${OPT_TLS_KEY:-}" ]] ||
            die "--tls-cert and --tls-key must be supplied together" "$HY2_EX_USAGE"
        hysteria_validate_cert_key "$OPT_TLS_CERT" "$OPT_TLS_KEY" ||
            die "the supplied TLS certificate/key are unreadable, invalid, or do not match" "$HY2_EX_USAGE"
        TLS_CERT="$(readlink -f "$OPT_TLS_CERT")"
        TLS_KEY="$(readlink -f "$OPT_TLS_KEY")"
        TLS_MODE="provided"
        TLS_PIN=""
    else
        TLS_MODE="self-signed-pinned"
        if valid_ipv4 "$TLS_SNI"; then san="IP:$TLS_SNI"; else san="DNS:$TLS_SNI"; fi
        if [[ ! -s "$dir/server.crt" || ! -s "$dir/server.key" ]]; then
            log_info "Generating a pinned self-signed TLS certificate for $TLS_SNI"
            openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 825 \
                -subj "/CN=$TLS_SNI" -addext "subjectAltName=$san" \
                -keyout "$dir/server.key" -out "$dir/server.crt" >/dev/null 2>&1 ||
                die "could not generate the Hysteria2 TLS certificate" "$HY2_EX_ENV"
        fi
        chmod 600 "$dir/server.key"
        chmod 644 "$dir/server.crt"
        TLS_PIN="$(hysteria_cert_pin "$dir/server.crt")"
        [[ "$TLS_PIN" =~ ^[0-9a-f]{64}$ ]] || die "could not fingerprint the TLS certificate" "$HY2_EX_ENV"
    fi
    if [[ "$TLS_MODE" == "self-signed-pinned" ]]; then
        TLS_CERT="$dir/server.crt"
        TLS_KEY="$dir/server.key"
    fi
}

inbound_build_json() {
    jq -n --arg remark "$INBOUND_REMARK" --argjson port "$PORT" --arg addr "$SERVER_ADDR" \
        --arg cert "$TLS_CERT" --arg key "$TLS_KEY" --arg sni "$TLS_SNI" --arg pin "$TLS_PIN" '
      {
        enable: true, remark: $remark, listen: "", port: $port, protocol: "hysteria",
        expiryTime: 0, total: 0, trafficReset: "never", trafficResetDay: 1,
        shareAddrStrategy: "custom", shareAddr: $addr,
        settings: {version: 2, clients: []},
        streamSettings: {
          network: "hysteria",
          security: "tls",
          hysteriaSettings: {version: 2, udpIdleTimeout: 60},
          tlsSettings: {
            serverName: $sni, minVersion: "1.2", maxVersion: "1.3",
            cipherSuites: "", rejectUnknownSni: false, disableSystemRoot: false,
            enableSessionResumption: false, alpn: ["h3"], echServerKeys: "",
            certificates: [{certificateFile: $cert, keyFile: $key, oneTimeLoading: false, usage: "encipherment", buildChain: false}],
            settings: {fingerprint: "", echConfigList: "", verifyPeerCertByName: "", pinnedPeerCertSha256: (if $pin == "" then [] else [$pin] end)}
          }
        },
        sniffing: {enabled: false}
      }'
}

declare -gA LINK_P=()
LINK_AUTH="" LINK_HOST="" LINK_PORT="" LINK_NAME=""

link_parse() {
    local link="$1" rest hostport query kv k v
    LINK_P=() LINK_AUTH="" LINK_HOST="" LINK_PORT="" LINK_NAME=""
    [[ "$link" == hysteria2://* || "$link" == hy2://* ]] || return 1
    rest="${link#*://}"
    [[ "$rest" == *@* ]] || return 1
    LINK_AUTH="$(hy2_urldecode "${rest%%@*}")"
    rest="${rest#*@}"
    if [[ "$rest" == *"#"* ]]; then LINK_NAME="$(hy2_urldecode "${rest#*#}")"; rest="${rest%%#*}"; fi
    hostport="${rest%%\?*}"
    query=""; [[ "$rest" == *\?* ]] && query="${rest#*\?}"
    if [[ "$hostport" == \[*\]:* ]]; then
        LINK_HOST="${hostport%%]:*}"; LINK_HOST="${LINK_HOST#[}"
    else
        LINK_HOST="${hostport%:*}"
    fi
    LINK_PORT="${hostport##*:}"
    [[ -n "$LINK_AUTH" && -n "$LINK_HOST" ]] && valid_port "$LINK_PORT" || return 1
    local -a pairs=(); IFS='&' read -r -a pairs <<<"$query"
    for kv in "${pairs[@]}"; do
        [[ -n "$kv" ]] || continue
        k="${kv%%=*}"; v=""; [[ "$kv" == *=* ]] && v="${kv#*=}"
        LINK_P["$k"]="$(hy2_urldecode "$v")"
    done
}

link_validate() {
    local link="$1" want_auth="${2:-}" problems=()
    link_parse "$link" || { echo "not a valid hysteria2:// or hy2:// URI"; return 1; }
    [[ -z "$want_auth" || "$LINK_AUTH" == "$want_auth" ]] || problems+=("client auth mismatch")
    [[ "$LINK_HOST" == "$SERVER_ADDR" ]] || problems+=("host '$LINK_HOST' != '$SERVER_ADDR'")
    [[ "$LINK_PORT" == "$PORT" ]] || problems+=("port '$LINK_PORT' != '$PORT'")
    [[ "${LINK_P[security]:-tls}" == "tls" ]] || problems+=("security is not tls")
    [[ "${LINK_P[sni]:-}" == "$TLS_SNI" ]] || problems+=("SNI mismatch")
    [[ "${LINK_P[alpn]:-h3}" == *h3* ]] || problems+=("ALPN does not include h3")
    if [[ -n "$TLS_PIN" ]]; then
        [[ "${LINK_P[pinSHA256]:-}" == "$TLS_PIN" ]] || problems+=("certificate pin mismatch")
    fi
    if ((${#problems[@]})); then printf '%s\n' "${problems[@]}"; return 1; fi
}
