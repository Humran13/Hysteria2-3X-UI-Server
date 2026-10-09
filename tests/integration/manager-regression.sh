#!/usr/bin/env bash
# Focused manager/update/repair/scoped-uninstall regression. Run after lifecycle setup.
set -Eeuo pipefail

state=/etc/hysteria2-3x-ui-server/state.json
installed=/opt/hysteria2-3x-ui-server
[[ -f "$state" && -d "$installed" ]]

uri_before="$(hysteria2 export client1 --format uri)"
auth_before="$(jq -r '.clients | sort_by(.email) | .[].auth' "$state" | sha256sum | awk '{print $1}')"
cert="$(jq -r '.tls.cert' "$state")"
key="$(jq -r '.tls.key' "$state")"
cert_before="$(sha256sum "$cert" | awk '{print $1}')"
key_before="$(sha256sum "$key" | awk '{print $1}')"
token="$(tr -d '[:space:]' </etc/hysteria2-3x-ui-server/api-token)"
first_auth="$(jq -r '.clients[0].auth' "$state")"

hysteria2 status >/tmp/manager-status.txt
hysteria2 info client1 >/tmp/manager-info.txt
hysteria2 clients >/tmp/manager-clients.txt
hysteria2 qr client1 >/tmp/manager-qr.txt
hysteria2 diagnostics >/tmp/manager-diagnostics.txt
hysteria2 logs >/tmp/manager-logs.txt
if grep -Fq "$token" /tmp/manager-logs.txt || grep -Fq "$first_auth" /tmp/manager-logs.txt; then
    echo 'manager logs exposed a stored secret' >&2
    exit 1
fi

hysteria2 add-client RemoveMe >/dev/null
hysteria2 --yes remove-client RemoveMe
! hysteria2 clients | grep -q '^RemoveMe[[:space:]]'

hysteria2 repair
[[ "$(hysteria2 export client1 --format uri)" == "$uri_before" ]]
[[ "$(jq -r '.clients | sort_by(.email) | .[].auth' "$state" | sha256sum | awk '{print $1}')" == "$auth_before" ]]
[[ "$(sha256sum "$cert" | awk '{print $1}')" == "$cert_before" ]]
[[ "$(sha256sum "$key" | awk '{print $1}')" == "$key_before" ]]

hysteria2 --yes update --panel-version v3.9.0
[[ "$(hysteria2 export client1 --format uri)" == "$uri_before" ]]
hysteria2 --yes update --self
[[ "$(hysteria2 export client1 --format uri)" == "$uri_before" ]]

# Create a valid, deliberately unrelated inbound through the same public panel API.
# Level-1 uninstall must leave it and the 3X-UI service intact.
# shellcheck source=/dev/null
for module in common validate os network upstream api state hysteria firewall client output installer repair diagnostics backup update uninstall; do
    . "$installed/lib/$module.sh"
done
hy2_tmp_init
state_load
api_session_init
panel_inbound_get "$INBOUND_ID"
unrelated_body="$(hy2_mktemp unrelated)"
jq '.obj
    | del(.id, .tag, .clientStats, .up, .down, .lastTrafficResetTime)
    | .remark = "Unrelated-Audit"
    | .port = 18443
    | .settings = {version: 2, clients: []}' "$API_OUT" >"$unrelated_body"
panel_inbound_add "$unrelated_body"
unrelated_id="$(api_obj '.obj.id')"
[[ "$unrelated_id" =~ ^[0-9]+$ ]]

hysteria2 --yes uninstall --level 1
systemctl is-active --quiet x-ui

# The wrapper token was intentionally removed. Reacquire the upstream install token
# and prove that only the unrelated inbound remains.
api_configure
upstream_result_load
api_set_token "$XUI_API_TOKEN"
panel_inbound_get "$unrelated_id"
[[ "$(api_obj '.obj.remark')" == 'Unrelated-Audit' ]]
if panel_inbound_get "$INBOUND_ID"; then
    echo 'managed inbound survived level-1 uninstall' >&2
    exit 1
fi
[[ ! -e /etc/hysteria2-3x-ui-server/state.json ]]

echo 'MANAGER_REGRESSION_AND_SCOPED_UNINSTALL_OK'
