#!/usr/bin/env bash
#
# Smoke test a built image.
#
# Usage: smoke.sh IMAGE
#
# The image serves MCP from the same nginx as the web GUI. Both ports default
# to 9300, so a single port carries everything unless MCP_LISTENING_PORT is
# moved elsewhere. The three cases below are covered:
#
#   shared  MCP and the GUI on one port (the defaults),
#   auth    the same, with the web login page in front of the GUI,
#   split   the GUI and MCP on different ports.
#
# Every case verifies that:
#   - the web GUI answers,
#   - MCP rejects requests without a valid token with 401 + WWW-Authenticate,
#   - MCP initialize succeeds with the token and reports browseros-neo,
#   - MCP tools/list returns tools,
#   - an event stream (SSE) passes through the proxy without buffering,
#   - the renderer runs with the Chromium sandbox,
#   - the window supervisor restores a minimized window, even when another
#     window is visible, and the switching keys are installed.

set -euo pipefail

IMAGE="${1:?usage: smoke.sh IMAGE}"
# 64 hex characters, the same shape as `openssl rand -hex 32`.
TOKEN="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
WEB_USERNAME="smoke"
WEB_PASSWORD="smoke-password-0123456789abcdef"
TIMEOUT="${SMOKE_TIMEOUT:-180}"
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}'

CONTAINER=""

cleanup() {
    status=$?
    if [ "${status}" -ne 0 ] && [ -n "${CONTAINER}" ]; then
        echo "---- container logs (${CONTAINER}) ----"
        docker logs "${CONTAINER}" 2>&1 | tail -n 400 || true
        echo "---- container state ----"
        docker exec "${CONTAINER}" sh -c '
            ls -l /var/tmp/nginx/*.conf
            echo "-- generated MCP configuration"
            cat /var/tmp/nginx/mcp.conf /var/tmp/nginx/mcp_site.conf
            echo "-- includes"
            grep -n "include" /opt/base/etc/nginx/default_site.conf /opt/base/etc/nginx/nginx.conf
            echo "-- nginx error log"
            tail -n 50 /config/log/nginx/error.log
        ' 2>&1 || true
    fi
    if [ -n "${CONTAINER}" ]; then
        docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }

# Fail right away instead of waiting out the timeout when the container exited.
assert_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)" = true ] \
        || fail "the container exited"
}

start_container() {
    # $1 = scenario name, the rest = docker run arguments
    local name="$1"
    shift
    CONTAINER="browseros-neo-smoke-$$-${name}"
    docker run -d --name "${CONTAINER}" \
        --shm-size 2g \
        --security-opt seccomp=unconfined \
        "$@" "${IMAGE}" >/dev/null
}

stop_container() {
    if [ -n "${CONTAINER}" ]; then
        docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
        CONTAINER=""
    fi
}

host_port() {
    docker port "${CONTAINER}" "$1/tcp" | head -n1 | sed 's/.*://'
}

# mcp URL TOKEN BODY [extra curl args...]
mcp() {
    local url="$1" token="$2" body="$3"
    shift 3
    curl -sS -m 15 \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d "${body}" "$@" "${url}"
}

# wait_status URL EXPECTED_CODES DESCRIPTION
wait_status() {
    local url="$1" want="$2" what="$3" code
    local deadline=$((SECONDS + TIMEOUT))
    while :; do
        code="$(curl -s -o /dev/null -w '%{http_code}' "${url}" || true)"
        case " ${want} " in
            *" ${code} "*) return 0 ;;
        esac
        assert_running
        [ "${SECONDS}" -lt "${deadline}" ] || fail "${what} did not answer (last status ${code:-none})"
        sleep 2
    done
}

# wait_body URL EXPECTED DESCRIPTION
wait_body() {
    local url="$1" want="$2" what="$3" body code
    local deadline=$((SECONDS + TIMEOUT))
    while :; do
        body="$(curl -s "${url}" || true)"
        [ "${body}" = "${want}" ] && return 0
        assert_running
        [ "${SECONDS}" -lt "${deadline}" ] || {
            code="$(curl -s -o /dev/null -w '%{http_code}' "${url}" || true)"
            fail "${what} answered ${code:-nothing} with '${body}', want '${want}'"
        }
        sleep 2
    done
}

# wait_mcp URL DESCRIPTION
wait_mcp() {
    local url="$1" what="$2"
    local deadline=$((SECONDS + TIMEOUT))
    while :; do
        if mcp "${url}" "${TOKEN}" "${INIT}" 2>/dev/null | grep -q '"serverInfo"'; then
            return 0
        fi
        assert_running
        [ "${SECONDS}" -lt "${deadline}" ] || fail "${what} did not become ready"
        sleep 3
    done
}

# check_stream URL SESSION LABEL
check_stream() {
    local url="$1" session="$2" label="$3" body status
    body="$(mktemp)"
    # The server keeps this stream open and flushes its first event right away.
    # A buffering proxy would deliver nothing until the connection closed, so
    # seeing an event while curl is still running out its timeout proves that
    # the response passes through.
    status="$(curl -sS -N -m 8 -o "${body}" -w '%{http_code}' \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Mcp-Session-Id: ${session}" \
        -H 'Accept: text/event-stream' "${url}" 2>/dev/null || true)"
    [ "${status}" = 200 ] || fail "${label}: event stream returned status ${status}, want 200"
    grep -q '^data:' "${body}" || fail "${label}: event stream delivered no event before its timeout"
    rm -f "${body}"
    ok "${label}: event stream (SSE) passes through the proxy"
}

# check_mcp URL LABEL
check_mcp() {
    local url="$1" label="$2" code headers body session tools

    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "${INIT}" "${url}")"
    [ "${code}" = 401 ] || fail "${label}: request without a token returned ${code}, want 401"
    curl -s -D - -o /dev/null -X POST -H 'Content-Type: application/json' -d "${INIT}" "${url}" \
        | grep -qi '^www-authenticate:' || fail "${label}: 401 without a WWW-Authenticate challenge"
    ok "${label}: MCP without a token returns 401 with a challenge"

    code="$(mcp "${url}" "wrong-token-0123456789abcdef" "${INIT}" -o /dev/null -w '%{http_code}')"
    [ "${code}" = 401 ] || fail "${label}: request with a wrong token returned ${code}, want 401"

    headers="$(mktemp)"
    body="$(mcp "${url}" "${TOKEN}" "${INIT}" -D "${headers}")"
    grep -q '"name":"browseros-neo"' <<<"${body}" || fail "${label}: unexpected initialize response: ${body}"
    session="$(grep -i '^mcp-session-id:' "${headers}" | head -n1 | cut -d' ' -f2 | tr -d '\r')"
    rm -f "${headers}"
    [ -n "${session}" ] || fail "${label}: initialize returned no session id"
    ok "${label}: MCP initialize reports browseros-neo (session ${session})"

    mcp "${url}" "${TOKEN}" '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        -H "Mcp-Session-Id: ${session}" -H "MCP-Protocol-Version: 2025-06-18" -o /dev/null
    tools="$(mcp "${url}" "${TOKEN}" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
        -H "Mcp-Session-Id: ${session}" -H "MCP-Protocol-Version: 2025-06-18")"
    grep -q '"tools"' <<<"${tools}" || fail "${label}: unexpected tools/list response: ${tools}"
    ok "${label}: MCP tools/list returns tools"

    check_stream "${url}" "${session}" "${label}"
}

check_sandbox() {
    if docker exec "${CONTAINER}" sh -c 'pgrep -f -- "--type=renderer" | head -n1 | xargs -I{} cat /proc/{}/cmdline' \
        | tr '\0' '\n' | grep -qx -- '--no-sandbox'; then
        fail "the renderer runs without the Chromium sandbox"
    fi
    ok "Chromium sandbox enabled"
}

# check_window_handling
#
# The window supervisor must keep the application's windows mapped, must put a
# restored window behind the window that is in use, and the Openbox
# configuration must carry the switching keys. The second window is simulated
# with yad, which can be given the WM_CLASS the supervisor matches, so the check
# does not depend on the application's own shortcuts.
check_window_handling() {
    docker exec "${CONTAINER}" grep -q 'C-F6' /var/run/openbox/rc.xml \
        || fail "the Openbox configuration has no Ctrl+F6 binding"

    if ! docker exec -i "${CONTAINER}" sh -s <<'EOF'
set -e

export DISPLAY=:0

XDOTOOL=/usr/bin/xdotool
OBXPROP=/opt/base/bin/obxprop

visible_windows() { "${XDOTOOL}" search --onlyvisible --classname '^chromium-browser' 2>/dev/null; }
is_hidden() { "${OBXPROP}" --id "$1" _NET_WM_STATE 2>/dev/null | grep -q _NET_WM_STATE_HIDDEN; }
not_hidden() { ! is_hidden "$1"; }
stack_top() { "${OBXPROP}" --root _NET_CLIENT_LIST_STACKING 2>/dev/null | sed 's/^.*= //' | awk -F, '{print $NF}' | tr -d ' '; }
active_window() { "${XDOTOOL}" getactivewindow 2>/dev/null || echo none; }

# wait_until DESCRIPTION COMMAND...
wait_until() {
    what="$1"
    shift
    i=0
    while [ "${i}" -lt 30 ]; do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 1
        i=$((i + 1))
    done
    echo "FAIL: ${what} did not happen within 30s" >&2
    return 1
}

# The application window, and a minimized window coming back.
wait_until "the application window to appear" visible_windows
app="$(visible_windows | head -n1)"
"${XDOTOOL}" windowactivate "${app}"
sleep 1
"${XDOTOOL}" windowminimize "${app}"
wait_until "the minimized application window to come back" not_hidden "${app}"

# A second window: minimizing it must not put it in front of the window in use.
/opt/base/bin/yad --name='chromium-browser (smoke)' --class='Chromium-browser' \
    --title='smoke test window' --text='smoke' --width=200 --height=100 >/dev/null 2>&1 &
yad_pid=$!
wait_until "the second window to appear" sh -c '[ "$(xdotool search --onlyvisible --classname "^chromium-browser" | wc -l)" -ge 2 ]'
second="$(visible_windows | grep -v "^${app}$" | head -n1)"
"${XDOTOOL}" windowactivate "${second}"
sleep 1
[ "$(active_window)" = "${second}" ] || { echo "FAIL: could not bring the second window to the front" >&2; exit 1; }
"${XDOTOOL}" windowminimize "${second}"
wait_until "the minimized second window to come back" not_hidden "${second}"
[ "$(stack_top)" != "${second}" ] || { echo "FAIL: the restored window was put in front of the window in use" >&2; exit 1; }
[ "$(active_window)" = "${app}" ] || { echo "FAIL: the window in use lost the focus to the restored window" >&2; exit 1; }

# The switching keys.
before="$(active_window)"
"${XDOTOOL}" key --clearmodifiers ctrl+F6
sleep 1
[ "$(active_window)" != "${before}" ] || { echo "FAIL: Ctrl+F6 did not switch windows" >&2; exit 1; }
"${XDOTOOL}" key --clearmodifiers ctrl+shift+F6
sleep 1
[ "$(active_window)" = "${before}" ] || { echo "FAIL: Ctrl+Shift+F6 did not switch back" >&2; exit 1; }

kill "${yad_pid}" 2>/dev/null || true
EOF
    then
        fail "the window supervisor did not behave as expected"
    fi

    ok "the window supervisor restores minimized windows and the switching keys work"
}

# MCP and the GUI on the same port (the defaults).
echo "== MCP and the web GUI on one port"
start_container shared \
    -e MCP_AUTH_TOKEN="${TOKEN}" \
    -p 127.0.0.1::9300
PORT="$(host_port 9300)"
WEB_URL="http://127.0.0.1:${PORT}"
wait_status "${WEB_URL}/" 200 "the web GUI"
wait_body "${WEB_URL}/healthz" ok "the health check"
wait_mcp "${WEB_URL}/mcp" "MCP"
check_mcp "${WEB_URL}/mcp" "shared port"
check_sandbox
check_window_handling
stop_container

# The same port, now with the login page in front of the GUI. MCP must keep
# answering with 401 instead of being redirected to the login page.
echo "== MCP on the web port with web authentication enabled"
start_container auth \
    -e MCP_AUTH_TOKEN="${TOKEN}" \
    -e WEB_AUTHENTICATION=1 \
    -e WEB_AUTHENTICATION_ALLOW_INSECURE=1 \
    -e WEB_AUTHENTICATION_USERNAME="${WEB_USERNAME}" \
    -e WEB_AUTHENTICATION_PASSWORD="${WEB_PASSWORD}" \
    -p 127.0.0.1::9300
PORT="$(host_port 9300)"
WEB_URL="http://127.0.0.1:${PORT}"
wait_status "${WEB_URL}/" 302 "the login redirect"
deadline=$((SECONDS + TIMEOUT))
until curl -s -D - -o /dev/null "${WEB_URL}/" | grep -qi '^location: /login/'; do
    assert_running
    [ "${SECONDS}" -lt "${deadline}" ] || fail "the web GUI does not redirect to the login page"
    sleep 2
done
ok "the web GUI redirects to the login page"
wait_mcp "${WEB_URL}/mcp" "MCP"
check_mcp "${WEB_URL}/mcp" "web authentication"
stop_container

# MCP on a port of its own.
echo "== MCP on its own port"
start_container split \
    -e MCP_AUTH_TOKEN="${TOKEN}" \
    -e WEB_LISTENING_PORT=5800 \
    -e MCP_LISTENING_PORT=9300 \
    -p 127.0.0.1::5800 \
    -p 127.0.0.1::9300
WEB_URL="http://127.0.0.1:$(host_port 5800)"
MCP_URL="http://127.0.0.1:$(host_port 9300)"
wait_status "${WEB_URL}/" 200 "the web GUI"
wait_body "${MCP_URL}/healthz" ok "the health check"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "${INIT}" "${WEB_URL}/mcp")"
[ "${code}" = 404 ] || fail "the web port answered ${code} for /mcp, want 404"
ok "the web port serves no MCP when the ports differ"
wait_mcp "${MCP_URL}/mcp" "MCP"
check_mcp "${MCP_URL}/mcp" "separate port"
stop_container

echo "All smoke tests passed."
