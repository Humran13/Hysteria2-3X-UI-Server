#!/usr/bin/env bash
# shellcheck shell=bash
# api.sh - client for the official 3X-UI HTTP API (Bearer token, localhost). No database access, ever.
#
# Conventions: every request body lives in a private temp file (never on the command line); the token is passed to curl
# through a config on a pipe (never visible in `ps`). The last JSON response is kept in $API_OUT.

API_BASE="" API_TOKEN="" API_OUT="" API_MSG="" API_HTTP=""
API_CURL_EXTRA=()
API_TOKEN_NAME="hysteria2-3x-ui-server"

# Resolve the base URL: explicit override (HY2_PANEL_URL) or the panel's own settings, always via localhost.
api_configure() {
    API_CURL_EXTRA=()
    if [[ -n "${HY2_PANEL_URL:-}" ]]; then
        API_BASE="${HY2_PANEL_URL%/}"
        return 0
    fi
    upstream_panel_settings || {
        log_err "cannot read panel settings from $UPSTREAM_DIR/x-ui (is 3X-UI installed?)"
        return 1
    }
    local scheme="http" host="127.0.0.1"
    if [[ -n "$PANEL_CERT" && -r "$PANEL_CERT" ]]; then
        # TLS-enabled panel: connect to localhost but verify against the certificate's own name (no -k, ever).
        scheme="https"
        host="$(openssl x509 -in "$PANEL_CERT" -noout -ext subjectAltName 2>/dev/null | grep -Eo '(DNS:|IP Address:)[^, ]+' | head -n1 | sed -E 's/^(DNS:|IP Address:)//' || true)"
        if [[ -z "$host" ]]; then
            log_err "the panel uses TLS but its certificate name could not be determined; set HY2_PANEL_URL"
            return 1
        fi
        API_CURL_EXTRA=(--connect-to "${host}:${PANEL_PORT}:127.0.0.1:${PANEL_PORT}")
    fi
    if [[ -n "$PANEL_BASE_PATH" ]]; then
        API_BASE="${scheme}://${host}:${PANEL_PORT}/${PANEL_BASE_PATH}"
    else
        API_BASE="${scheme}://${host}:${PANEL_PORT}"
    fi
}

# api_request METHOD PATH [BODYFILE [CONTENT_TYPE]]
# Return: 0 ok | 20 transport error | 21 non-200 HTTP | 22 malformed JSON | 23 success=false
api_request() {
    local method="$1" path="$2" body="${3:-}" ctype="${4:-application/json}" http rc=0
    [[ -n "$API_BASE" && -n "$API_TOKEN" ]] || {
        API_MSG="api not configured"
        return 20
    }
    hy2_tmp_init
    API_OUT="$HY2_TMP/api-last.json"
    : >"$API_OUT"
    API_MSG="" API_HTTP=""
    local args=(-sS --connect-timeout 5 --max-time 60 -o "$API_OUT" -w '%{http_code}' -X "$method" -H 'Accept: application/json')
    if [[ -n "$body" ]]; then
        args+=(-H "Content-Type: ${ctype}" --data-binary "@$body")
    fi
    http="$(curl "${args[@]}" "${API_CURL_EXTRA[@]}" -K <(printf 'header = "Authorization: Bearer %s"\n' "$API_TOKEN") "${API_BASE}${path}" 2>/dev/null)" || rc=$?
    if ((rc != 0)); then
        API_MSG="cannot reach the 3X-UI panel API (curl exit $rc)"
        return 20
    fi
    API_HTTP="$http"
    if [[ "$http" != "200" ]]; then
        case "$http" in
            401) API_MSG="the panel rejected our API token (HTTP 401)" ;;
            404) API_MSG="panel API path not found (HTTP 404) - wrong base path or unsupported 3X-UI version" ;;
            *) API_MSG="unexpected HTTP status $http from the panel API" ;;
        esac
        return 21
    fi
    if ! jq -e 'type == "object" and has("success")' "$API_OUT" >/dev/null 2>&1; then
        API_MSG="malformed response from the panel API (not the expected JSON envelope)"
        return 22
    fi
    if [[ "$(jq -r '.success' "$API_OUT")" != "true" ]]; then
        API_MSG="$(jq -r '.msg // "request failed"' "$API_OUT" | tr '\n' ' ')"
        return 23
    fi
    return 0
}

api_get() { api_request GET "$1"; }
api_post() { api_request POST "$1" "${2:-}"; }
api_post_form() { api_request POST "$1" "$2" application/x-www-form-urlencoded; }
# jq over the last response's .obj
api_obj() { jq -r "$1" "$API_OUT"; }

# Authenticated raw download to a file (for backups).
api_download() {
    local path="$1" dest="$2" http rc=0
    http="$(curl -sS --connect-timeout 5 --max-time 120 -o "$dest" -w '%{http_code}' "${API_CURL_EXTRA[@]}" -K <(printf 'header = "Authorization: Bearer %s"\n' "$API_TOKEN") "${API_BASE}${path}" 2>/dev/null)" || rc=$?
    ((rc == 0)) && [[ "$http" == "200" ]]
}

# Authenticated multipart upload (restore).
api_upload() {
    local path="$1" field="$2" file="$3" http rc=0
    hy2_tmp_init
    API_OUT="$HY2_TMP/api-last.json"
    http="$(curl -sS --connect-timeout 5 --max-time 180 -o "$API_OUT" -w '%{http_code}' -X POST "${API_CURL_EXTRA[@]}" -K <(printf 'header = "Authorization: Bearer %s"\n' "$API_TOKEN") -F "${field}=@${file}" "${API_BASE}${path}" 2>/dev/null)" || rc=$?
    ((rc == 0)) && [[ "$http" == "200" ]] && jq -e '.success == true' "$API_OUT" >/dev/null 2>&1
}

api_set_token() {
    API_TOKEN="$1"
    hy2_secret_add "$API_TOKEN"
}

# Wait until the panel API answers with a valid token.
api_wait_ready() {
    local timeout="${1:-60}" i
    for ((i = 0; i < timeout; i++)); do
        if api_get /panel/api/server/status; then
            return 0
        fi
        # a 401 means the panel is up but the token is wrong; no point waiting
        [[ "$API_HTTP" == "401" ]] && return 1
        sleep 1
    done
    return 1
}

# Find a working API token. Order: env override, our own token file, upstream install-result.env.
# Never regenerates or resets anything.
api_acquire_token() {
    local cand src
    local -a sources=()
    [[ -n "${HY2_XUI_API_TOKEN:-}" ]] && sources+=(env)
    [[ -r "$HY2_STATE_DIR/api-token" ]] && sources+=(file)
    [[ -f "$UPSTREAM_RESULT_FILE" ]] && sources+=(result)
    for src in "${sources[@]}"; do
        cand=""
        case "$src" in
            env) cand="$HY2_XUI_API_TOKEN" ;;
            file) cand="$(tr -d '[:space:]' <"$HY2_STATE_DIR/api-token")" ;;
            result) upstream_result_load && cand="$XUI_API_TOKEN" ;;
        esac
        [[ -n "$cand" ]] || continue
        api_set_token "$cand"
        # right after a (re)start the panel may briefly reject valid tokens: give our own token a few chances
        local attempt max=1
        [[ "$src" == "file" ]] && max=4
        for ((attempt = 0; attempt < max; attempt++)); do
            if api_get /panel/api/server/status; then
                API_TOKEN_SOURCE="$src"
                return 0
            fi
            [[ "$API_HTTP" == "401" && "$src" == "file" ]] || break
            sleep 2
        done
        log_debug "API token from '$src' is not usable: $API_MSG"
    done
    API_TOKEN=""
    return 1
}
API_TOKEN_SOURCE=""

# Mint (and store) a dedicated admin token so we do not depend on install-result.env staying around.
api_ensure_own_token() {
    if [[ "$API_TOKEN_SOURCE" == "file" ]]; then
        return 0
    fi
    local body tok id
    body="$(hy2_mktemp tok)"
    jq -n --arg n "${API_TOKEN_NAME}-$(hy2_random_alnum 5)" '{name:$n, scope:"admin", expiresAt:0}' >"$body"
    if ! api_post /panel/api/setting/apiTokens/create "$body"; then
        log_warn "could not create a dedicated API token ($API_MSG); falling back to the existing token"
        return 0
    fi
    tok="$(api_obj '.obj.token // empty')"
    id="$(api_obj '.obj.id // empty')"
    if [[ -z "$tok" ]]; then
        log_warn "panel did not return a token; keeping the existing one"
        return 0
    fi
    api_set_token "$tok"
    (umask 077 && printf '%s\n' "$tok" | hy2_write_atomic "$HY2_STATE_DIR/api-token" 600) || {
        log_warn "could not store the dedicated API token"
        return 0
    }
    API_TOKEN_ID="$id"
    API_TOKEN_SOURCE="file"
    log_ok "Created a dedicated API token for the wrapper (stored root-only)"
}
API_TOKEN_ID=""

api_delete_own_token() {
    local id="${1:-}" body
    [[ -n "$id" ]] || return 0
    body="$(hy2_mktemp tokdel)"
    jq -n '{expectedScope:"admin"}' >"$body"
    api_post "/panel/api/setting/apiTokens/delete/${id}" "$body" || log_warn "could not delete our API token (id $id): $API_MSG"
}

# Delete EVERY token this wrapper ever minted (name prefix), the one currently in use last.
api_delete_all_own_tokens() {
    local ids id
    api_get /panel/api/setting/apiTokens || return 0
    ids="$(jq -r --arg p "$API_TOKEN_NAME" '[.obj[]? | select((.name // "") | startswith($p)) | .id] | .[]' "$API_OUT" 2>/dev/null || true)"
    for id in $ids; do
        [[ "$id" == "${STATE_API_TOKEN_ID:-}" ]] && continue
        api_delete_own_token "$id"
    done
    [[ -n "${STATE_API_TOKEN_ID:-}" ]] && api_delete_own_token "$STATE_API_TOKEN_ID"
    return 0
}

# ---------- typed wrappers (all official endpoints; see docs/upstream-research.md) ----------

panel_xray_state() { # prints state string (running|stop|error) or "unknown"
    if api_get /panel/api/server/status; then
        api_obj '.obj.xray.state // "unknown"'
    else
        echo unknown
    fi
}

panel_restart_xray() { api_post /panel/api/server/restartXrayService; }

# Poll until Xray reports "running" (it starts a few seconds after the panel). Returns 0/1; last state in XRAY_STATE.
XRAY_STATE=""
panel_wait_xray_running() {
    local timeout="${1:-45}" i
    for ((i = 0; i < timeout; i++)); do
        XRAY_STATE="$(panel_xray_state)"
        [[ "$XRAY_STATE" == "running" ]] && return 0
        sleep 1
    done
    return 1
}
panel_inbounds_list() { api_get /panel/api/inbounds/list; }
panel_inbound_get() { api_get "/panel/api/inbounds/get/$1"; }
panel_inbound_add() { api_post /panel/api/inbounds/add "$1"; }
panel_inbound_update() { api_post "/panel/api/inbounds/update/$1" "$2"; }
panel_inbound_del() { api_post "/panel/api/inbounds/del/$1"; }

# Percent-encode a path segment (emails are validated to [A-Za-z0-9._-] but be safe).
_urlenc() { jq -rn --arg s "$1" '$s|@uri'; }

panel_client_add() { api_post /panel/api/clients/add "$1"; }
panel_client_get() { api_get "/panel/api/clients/get/$(_urlenc "$1")"; }
panel_client_update() { api_post "/panel/api/clients/update/$(_urlenc "$1")" "$2"; }
panel_client_del() { api_post "/panel/api/clients/del/$(_urlenc "$1")"; }
# Attach an existing (e.g. orphaned after an inbound was deleted) client record to inbound $2.
panel_client_attach() {
    local body
    body="$(hy2_mktemp attach)"
    jq -n --argjson id "$2" '{inboundIds: [$id]}' >"$body"
    api_post "/panel/api/clients/$(_urlenc "$1")/attach" "$body"
}
panel_client_links() { api_get "/panel/api/clients/links/$(_urlenc "$1")"; }
panel_clients_list() { api_get /panel/api/clients/list; }

# ---------- sessions ----------

# Configure base URL + find a working token, without failing (returns 1 and sets API_MSG on problems).
api_session_init_quiet() {
    api_configure || {
        API_MSG="cannot determine the panel URL"
        return 1
    }
    if api_acquire_token; then
        return 0
    fi
    if upstream_service_active; then
        API_MSG="no valid API token available (create one in the panel: Settings -> API Tokens, then export HY2_XUI_API_TOKEN=...)"
    else
        API_MSG="the x-ui service is not running"
    fi
    return 1
}

api_session_init() {
    api_session_init_quiet || die "$API_MSG" "$HY2_EX_API"
}

# Verify the running panel still exposes the endpoints this wrapper needs (guards against upstream API drift).
# /panel/api/openapi.json is a raw JSON document (not the {success,obj} envelope).
api_check_contract() {
    local spec missing
    spec="$(hy2_mktemp openapi)"
    if ! api_download /panel/api/openapi.json "$spec" || ! jq -e '.paths | type == "object"' "$spec" >/dev/null 2>&1; then
        log_warn "the panel does not publish an OpenAPI spec; skipping the API contract check"
        return 0
    fi
    missing="$(jq -r '
        ["/panel/api/inbounds/add", "/panel/api/inbounds/list", "/panel/api/inbounds/update/{id}", "/panel/api/inbounds/del/{id}",
         "/panel/api/clients/add", "/panel/api/clients/list", "/panel/api/clients/get/{email}", "/panel/api/clients/update/{email}",
         "/panel/api/clients/del/{email}", "/panel/api/clients/links/{email}",
         "/panel/api/server/getDb", "/panel/api/server/importDB", "/panel/api/server/status",
         "/panel/api/setting/apiTokens/create"] as $need
        | ($need - (.paths | keys)) | join(", ")' "$spec")"
    if [[ -n "$missing" ]]; then
        log_err "this 3X-UI version no longer exposes API endpoints the wrapper needs: $missing"
        log_err "The wrapper was validated against 3X-UI $TESTED_UPSTREAM. Update the wrapper (sudo hysteria2 update --self) or report an issue."
        return 1
    fi
    return 0
}
