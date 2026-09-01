#!/usr/bin/env bash
set -uo pipefail

: "${KUMA_PUSH_URL:?Missing KUMA_PUSH_URL}"
: "${DOCKER_PROXY_URL:?Missing DOCKER_PROXY_URL}"
: "${KUMA_CONTAINERS:?Missing KUMA_CONTAINERS}"

DOCKER_API_VERSION="${DOCKER_API_VERSION:-v1.46}"
KUMA_INTERVAL="${KUMA_INTERVAL:-60}"
KUMA_STARTING_STATE="${KUMA_STARTING_STATE:-skip}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"

push_base="${KUMA_PUSH_URL%/}"
api_base="${DOCKER_PROXY_URL%/}/${DOCKER_API_VERSION}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Map a container name to its token env var, then dereference it.
token_for() {
    local var="KUMA_TOKEN_${1^^}"
    var="${var//-/_}"
    printf '%s' "${!var-}"
}

# Send a single heartbeat. Uses -G so status/msg are URL encoded.
push() {
    local token="$1" status="$2" msg="$3"
    curl -sSk --retry 3 --retry-delay 2 --max-time "$CURL_TIMEOUT" -o /dev/null -G \
        --data-urlencode "status=${status}" \
        --data-urlencode "msg=${msg}" \
        "${push_base}/${token}"
}

report() {
    local name="$1" token="$2" status="$3" msg="$4"
    if push "$token" "$status" "$msg"; then
        log "[${name}] ${status} - ${msg}"
    else
        log "[${name}] ${status} - ${msg} (WARNING: push to Uptime Kuma failed)"
    fi
}

check() {
    local name="$1" token="$2"
    local resp code body health state

    # Trailing "\n<http_code>" lets us read body and status from one request.
    resp=$(curl -sk --max-time "$CURL_TIMEOUT" -w '\n%{http_code}' \
        "${api_base}/containers/${name}/json" 2>/dev/null)

    code="${resp##*$'\n'}"
    body="${resp%$'\n'*}"

    case "$code" in
        200) ;;
        404)
            report "$name" "$token" down "container ${name} does not exist"
            return ;;
        000|"")
            report "$name" "$token" down "docker-socket-proxy unreachable at ${DOCKER_PROXY_URL}"
            return ;;
        *)
            report "$name" "$token" down "docker api returned HTTP ${code}"
            return ;;
    esac

    # "Status" is the first key of both State and Health in the Engine API
    # response. '"Health":{' does not collide with '"Healthcheck":{'.
    state=$(printf '%s' "$body" | sed -n 's/.*"State":{"Status":"\([a-zA-Z]*\)".*/\1/p')
    health=$(printf '%s' "$body" | sed -n 's/.*"Health":{"Status":"\([a-zA-Z]*\)".*/\1/p')

    # A stopped container can retain a stale Health block, so gate on run state.
    if [[ $state != running ]]; then
        report "$name" "$token" down "container state: ${state:-unknown}"
        return
    fi

    if [[ -z $health ]]; then
        report "$name" "$token" up "running (no healthcheck defined)"
        return
    fi

    case "$health" in
        healthy)
            report "$name" "$token" up "healthy" ;;
        unhealthy)
            report "$name" "$token" down "unhealthy" ;;
        starting)
            case "${KUMA_STARTING_STATE,,}" in
                up)   report "$name" "$token" up   "starting" ;;
                down) report "$name" "$token" down "starting" ;;
                *)    log "[${name}] starting - no heartbeat sent" ;;
            esac ;;
        *)
            report "$name" "$token" down "unexpected health status: ${health}" ;;
    esac
}

trap 'log "Shutting down"; exit 0' TERM INT

IFS=', ' read -ra containers <<< "$KUMA_CONTAINERS"

log "Uptime Kuma docker health push starting"
log "Docker API:  ${api_base}"
log "Push base:   ${push_base}"
log "Interval:    ${KUMA_INTERVAL}s"
log "Starting state treated as: ${KUMA_STARTING_STATE}"

# Resolve tokens once and fail fast on anything missing.
names=() tokens=()
for name in "${containers[@]}"; do
    [[ -z $name ]] && continue
    tok=$(token_for "$name")
    if [[ -z $tok ]]; then
        var="KUMA_TOKEN_${name^^}"
        log "FATAL: no push token for '${name}'. Set ${var//-/_}"
        exit 1
    fi
    names+=("$name")
    tokens+=("$tok")
    log "Watching container: ${name}"
done

if [[ ${#names[@]} -eq 0 ]]; then
    log "FATAL: KUMA_CONTAINERS resolved to no container names"
    exit 1
fi

while true; do
    start=$SECONDS
    for i in "${!names[@]}"; do
        check "${names[i]}" "${tokens[i]}" &
    done
    wait

    sleep_for=$(( KUMA_INTERVAL - (SECONDS - start) ))
    (( sleep_for < 5 )) && sleep_for=5
    sleep "$sleep_for" &
    wait $! 2>/dev/null || true
done
