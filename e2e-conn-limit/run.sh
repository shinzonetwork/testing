#!/usr/bin/env bash
set -euo pipefail

# ───────────────────────────────────────────────────────────────
# Shinzo E2E conn-limit: how many libp2p connections does one generator
# accept from 1, 2, 3, 4 clients that share a single source IP?
#
# Every pod behind a k8s SNAT address reaches a generator from the same IP,
# so they share libp2p's per-IP budgets: a concurrent cap (default 8) and a
# new-connection rate limit (burst 16, then 1 per 5s). This harness puts N
# probe containers in one network namespace (one IP), has each open
# PER_PROBE connections from fresh peer identities, and records how many the
# target accepted, under each target config:
#
#   default    no new options: libp2p's limits
#   cap4       defradb.p2p.max_conns_per_ip=4
#   allowlist  defradb.p2p.allowlist_cidrs=<the shared IP>/32
#
# and two probe modes:
#
#   hold   connections stay open  → concurrent per-IP cap
#   churn  each closes on accept  → new-connection rate limit
#
# A distinct-IP control (N probes, N IPs, default config) shows the limit is
# per address, not per target.
#
# Images are built only from local sources (Dockerfile in this directory):
# the shinzo-indexer-client working tree plus DEFRADB_REF from the local
# defradb checkout. Nothing is pulled except the base images and anvil.
#
# Usage:
#   ./run.sh build          build shinzo-indexer:connlimit + shinzo-connprobe:connlimit
#   ./run.sh run            run the matrix → results/<timestamp>.{jsonl,md}
#   ./run.sh all            build, then run (default)
#   ./run.sh down           remove containers and network
#
# Env:
#   DEFRADB_REF=dvncan/connection-mgr-ratelimit   defradb ref to build against
#   DEFRADB_SRC=../../defradb  CLIENT_SRC=../../shinzo-indexer-client
#   COUNTS="1 2 3 4"  CONFIGS="default cap4 allowlist"  MODES="hold churn"
#   CONTROL=1         also run the distinct-IP control
#   PER_PROBE=40      connections each probe attempts
#   KEEP=1            leave containers up afterwards
# ───────────────────────────────────────────────────────────────

HERE="$(cd "$(dirname "$0")" && pwd)"
SNAP_DIR="$(cd "${HERE}/../.." && pwd)"
DEFRADB_SRC="${DEFRADB_SRC:-${SNAP_DIR}/defradb}"
CLIENT_SRC="${CLIENT_SRC:-${SNAP_DIR}/shinzo-indexer-client}"
DEFRADB_REF="${DEFRADB_REF:-dvncan/connection-mgr-ratelimit}"

TARGET_IMAGE="${TARGET_IMAGE:-shinzo-indexer:connlimit}"
PROBE_IMAGE="${PROBE_IMAGE:-shinzo-connprobe:connlimit}"
ANVIL_IMAGE="${ANVIL_IMAGE:-ghcr.io/foundry-rs/foundry:latest}"

COUNTS="${COUNTS:-1 2 3 4}"
CONFIGS="${CONFIGS:-default cap4 allowlist}"
MODES="${MODES:-hold churn}"
CONTROL="${CONTROL:-1}"
PER_PROBE="${PER_PROBE:-40}"
HEALTH_PORT="${HEALTH_PORT:-18180}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"

NET=e2e-connlimit
SUBNET=172.31.0.0/24
TARGET_IP=172.31.0.10
SHARED_IP=172.31.0.20          # the "SNAT address" every shared-IP probe uses
DISTINCT_BASE=30               # control probes use 172.31.0.31..34
CAP4=4
BURST_PER_CAP=2                # libp2p rate-limit burst = 2 × per-IP cap
DEFAULT_CAP=8
CHURN_SLACK=6                  # rate refill (0.2/s) during a churn case, per IP

log()  { printf '\033[1;34m[conn-limit]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[conn-limit]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[conn-limit]\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null || die "missing tool: $1"; }

# ── build ────────────────────────────────────────────────────────────────────

build() {
    need docker; need git; need tar
    docker info >/dev/null 2>&1 || die "Docker daemon is not running"
    [[ -d "${DEFRADB_SRC}/.git" ]] || die "DEFRADB_SRC=${DEFRADB_SRC} is not a git checkout"
    local sha ctx="${HERE}/.build"
    sha="$(git -C "${DEFRADB_SRC}" rev-parse --short "${DEFRADB_REF}")" || die "unknown defradb ref ${DEFRADB_REF}"

    rm -rf "${ctx}"; mkdir -p "${ctx}/client" "${ctx}/defradb"
    log "Context: client working tree + defradb ${DEFRADB_REF} (${sha})"
    # Working tree, so uncommitted client changes are tested; local state dirs stay out.
    tar -C "${CLIENT_SRC}" \
        --exclude ./.git --exclude './.defra*' --exclude ./bin --exclude ./keys \
        --exclude ./shinzo-data --exclude ./logs -cf - . | tar -x -C "${ctx}/client"
    # archive, not a copy: untracked files in the defradb checkout stay out
    git -C "${DEFRADB_SRC}" archive "${DEFRADB_REF}" | tar -x -C "${ctx}/defradb"
    cp -R "${HERE}/probe" "${ctx}/probe"
    cp "${HERE}/target.yaml" "${ctx}/target.yaml"

    log "Building ${TARGET_IMAGE}"
    docker build -f "${HERE}/Dockerfile" --target generator \
        --label "e2e.defradb_ref=${sha}" -t "${TARGET_IMAGE}" "${ctx}"
    log "Building ${PROBE_IMAGE}"
    docker build -f "${HERE}/Dockerfile" --target probe -t "${PROBE_IMAGE}" "${ctx}"
    rm -rf "${ctx}"
    log "Built ${TARGET_IMAGE} (defradb ${sha}) and ${PROBE_IMAGE}"
}

# ── topology ─────────────────────────────────────────────────────────────────

down() {
    docker rm -f cl-target cl-nat cl-anvil $(docker ps -aq --filter name=cl-probe-) >/dev/null 2>&1 || true
    docker network rm "${NET}" >/dev/null 2>&1 || true
}

up_base() {
    docker network inspect "${NET}" >/dev/null 2>&1 \
        || docker network create --subnet "${SUBNET}" "${NET}" >/dev/null
    if ! docker ps -q --filter name='^cl-anvil$' | grep -q .; then
        docker rm -f cl-anvil >/dev/null 2>&1 || true
        docker run -d --name cl-anvil --network "${NET}" --entrypoint anvil "${ANVIL_IMAGE}" \
            --host 0.0.0.0 --port 8545 --chain-id 1 >/dev/null
    fi
    # Holds the shared IP. Shared-IP probes join its network namespace, so every one of them
    # dials from SHARED_IP, as pods behind one SNAT address do.
    if ! docker ps -q --filter name='^cl-nat$' | grep -q .; then
        docker rm -f cl-nat >/dev/null 2>&1 || true
        docker run -d --name cl-nat --network "${NET}" --ip "${SHARED_IP}" \
            --entrypoint sleep "${PROBE_IMAGE}" infinity >/dev/null
    fi
}

# config → the env that selects it
config_env() {
    case "$1" in
        default)   ;;
        cap4)      echo "-e DEFRADB_P2P_MAX_CONNS_PER_IP=${CAP4}" ;;
        allowlist) echo "-e DEFRADB_P2P_ALLOWLIST_CIDRS=${SHARED_IP}/32" ;;
        *) die "unknown config $1" ;;
    esac
}

start_target() {
    local config="$1"
    docker rm -f cl-target >/dev/null 2>&1 || true
    # shellcheck disable=SC2046
    docker run -d --name cl-target --network "${NET}" --ip "${TARGET_IP}" \
        --ulimit nofile=65536:65536 -p "${HEALTH_PORT}:8080" \
        -e GETH_RPC_URL=http://cl-anvil:8545 -e GETH_WS_URL=ws://cl-anvil:8545 \
        -e GETH_API_KEY=test -e GETH_API_KEY_TYPE=none -e CHAIN_ID=1 \
        -e DEFRADB_KEYRING_SECRET=e2e-connlimit -e SCHEMA_AUTH_MODE=none \
        -e SNAPSHOT_ENABLED=false -e LOG_LEVEL=info \
        $(config_env "${config}") \
        "${TARGET_IMAGE}" >/dev/null
}

# Restarting keeps the container filesystem, so the peer ID is stable within a config while
# the resource manager - and its per-IP counters and rate buckets - start from empty.
restart_target() { docker restart cl-target >/dev/null; }

target_peer_id() {
    local id="" start="${SECONDS}"
    while [[ -z "${id}" ]]; do
        if (( SECONDS - start > HEALTH_TIMEOUT )); then
            docker logs --tail 60 cl-target >&2
            die "target: no peer ID after ${HEALTH_TIMEOUT}s"
        fi
        sleep 2
        id="$(curl -s --max-time 3 "http://localhost:${HEALTH_PORT}/health" 2>/dev/null \
            | jq -r '.p2p.self.id // empty' 2>/dev/null || true)"
    done
    echo "${id}"
}

# The startup line the client prints, so each result records the limits the node actually used.
target_limits_line() {
    local logs line
    logs="$(docker logs cl-target 2>&1)"
    line="$(grep -m1 -o 'P2P resource limits configured:[^"]*' <<<"${logs}" || true)"
    echo "${line:-(not found)}"
}

# ── one case ─────────────────────────────────────────────────────────────────

# expected <config> <n> <mode> <ipmode> → "lo hi"
expected() {
    local config="$1" n="$2" mode="$3" ipmode="$4" total=$(( $2 * PER_PROBE )) cap
    if [[ "${ipmode}" == distinct ]]; then
        cap="${DEFAULT_CAP}"
        if [[ "${mode}" == hold ]]; then echo "$(( n * cap )) $(( n * cap ))"
        else echo "$(( n * cap * BURST_PER_CAP )) $(( n * (cap * BURST_PER_CAP + CHURN_SLACK) ))"; fi
        return
    fi
    case "${config}" in
        allowlist) echo "${total} ${total}"; return ;;
        cap4)      cap="${CAP4}" ;;
        default)   cap="${DEFAULT_CAP}" ;;
    esac
    if [[ "${mode}" == hold ]]; then echo "${cap} ${cap}"
    else echo "$(( cap * BURST_PER_CAP )) $(( cap * BURST_PER_CAP + CHURN_SLACK ))"; fi
}

run_case() {
    local config="$1" n="$2" mode="$3" ipmode="$4" peer_id="$5" out="$6" limits="$7"
    local target="/ip4/${TARGET_IP}/tcp/9171/p2p/${peer_id}" i net names=() lines accepted lo hi verdict
    local -a extra=()
    [[ -n "${PROBE_ARGS:-}" ]] && read -r -a extra <<<"${PROBE_ARGS}"

    for i in $(seq 1 "${n}"); do
        if [[ "${ipmode}" == shared ]]; then net=(--network container:cl-nat)
        else net=(--network "${NET}" --ip "172.31.0.$(( DISTINCT_BASE + i ))"); fi
        docker run -d --name "cl-probe-${i}" "${net[@]}" "${PROBE_IMAGE}" \
            -target "${target}" -max "${PER_PROBE}" -mode "${mode}" -label "probe-${i}" "${extra[@]}" >/dev/null
        names+=("cl-probe-${i}")
    done
    docker wait "${names[@]}" >/dev/null

    lines="$(for c in "${names[@]}"; do docker logs "${c}" 2>/dev/null | sed -n 's/^RESULT //p'; done)"
    docker rm -f "${names[@]}" >/dev/null
    [[ "$(grep -c . <<<"${lines}")" == "${n}" ]] || die "expected ${n} probe results, got: ${lines}"

    # hold counts connections still open after settle; churn counts accepted connects.
    if [[ "${mode}" == hold ]]; then accepted="$(jq -s 'map(.alive) | add' <<<"${lines}")"
    else accepted="$(jq -s 'map(.connected) | add' <<<"${lines}")"; fi
    read -r lo hi <<<"$(expected "${config}" "${n}" "${mode}" "${ipmode}")"
    if (( accepted >= lo && accepted <= hi )); then verdict=PASS; else verdict=FAIL; fi

    jq -cn --arg config "${config}" --argjson n "${n}" --arg mode "${mode}" --arg ipmode "${ipmode}" \
        --argjson per_probe "${PER_PROBE}" --argjson accepted "${accepted}" \
        --argjson lo "${lo}" --argjson hi "${hi}" --arg verdict "${verdict}" --arg limits "${limits}" \
        --argjson probes "$(jq -s . <<<"${lines}")" \
        '{config:$config, clients:$n, mode:$mode, ip:$ipmode, per_probe:$per_probe,
          attempted:($n*$per_probe), accepted:$accepted, expected:{lo:$lo, hi:$hi},
          verdict:$verdict, target_limits:$limits, probes:$probes}' >> "${out}"
    log "$(printf '%-9s %-8s %-5s clients=%s accepted=%3s/%-3s expected=%s..%s  %s' \
        "${config}" "${ipmode}" "${mode}" "${n}" "${accepted}" "$(( n * PER_PROBE ))" "${lo}" "${hi}" "${verdict}")"
}

# ── matrix ───────────────────────────────────────────────────────────────────

report() {
    local jsonl="$1" md="$2"
    {
        echo "# Conn-limit e2e — $(basename "${jsonl}" .jsonl)"
        echo
        echo "Target: \`${TARGET_IMAGE}\` (defradb $(docker image inspect -f '{{ index .Config.Labels "e2e.defradb_ref" }}' "${TARGET_IMAGE}" 2>/dev/null)), ${PER_PROBE} connections attempted per client."
        echo "Shared IP = all clients dial from ${SHARED_IP} (one SNAT address); distinct = one IP each."
        echo
        echo "| config | ip | mode | clients | attempted | accepted | expected | result |"
        echo "|---|---|---|---:|---:|---:|---|---|"
        jq -r '"| \(.config) | \(.ip) | \(.mode) | \(.clients) | \(.attempted) | \(.accepted) | \(if .expected.lo == .expected.hi then "\(.expected.lo)" else "\(.expected.lo)–\(.expected.hi)" end) | \(.verdict) |"' "${jsonl}"
        echo
        echo "Target startup limits per config:"
        echo
        jq -r '"- \(.config): `\(.target_limits)`"' "${jsonl}" | sort -u
        echo
        echo "Dialer-side refusal reasons (all cases):"
        echo
        jq -r '.probes[].errors | to_entries[] | "\(.key)\t\(.value)"' "${jsonl}" \
            | awk -F'\t' '{c[$1]+=$2} END {for (k in c) printf "- `%s` × %d\n", k, c[k]}'
    } > "${md}"
}

run_matrix() {
    need docker; need jq; need curl
    docker info >/dev/null 2>&1 || die "Docker daemon is not running"
    docker image inspect "${TARGET_IMAGE}" >/dev/null 2>&1 || die "${TARGET_IMAGE} missing: run $0 build"
    docker image inspect "${PROBE_IMAGE}"  >/dev/null 2>&1 || die "${PROBE_IMAGE} missing: run $0 build"

    local ts out md config n mode peer_id limits fails
    ts="$(date +%Y%m%d-%H%M%S)"; mkdir -p "${HERE}/results"
    out="${HERE}/results/${ts}.jsonl"; md="${HERE}/results/${ts}.md"
    down; up_base
    [[ "${KEEP:-0}" == 1 ]] || trap down EXIT

    for config in ${CONFIGS}; do
        log "── config ${config}"
        start_target "${config}"
        peer_id="$(target_peer_id)"
        limits="$(target_limits_line)"
        log "target ${peer_id}: ${limits}"
        for mode in ${MODES}; do
            for n in ${COUNTS}; do
                restart_target; peer_id="$(target_peer_id)"
                run_case "${config}" "${n}" "${mode}" shared "${peer_id}" "${out}" "${limits}"
            done
            if [[ "${CONTROL}" == 1 && "${config}" == default ]]; then
                for n in ${COUNTS}; do
                    restart_target; peer_id="$(target_peer_id)"
                    run_case "${config}" "${n}" "${mode}" distinct "${peer_id}" "${out}" "${limits}"
                done
            fi
        done
    done

    report "${out}" "${md}"
    cat "${md}"
    fails="$(jq -s 'map(select(.verdict == "FAIL")) | length' "${out}")"
    log "results: ${out}"
    log "report:  ${md}"
    (( fails == 0 )) || die "${fails} case(s) FAILED"
    log "all cases PASS"
}

# ── ceiling: what happens past the connection manager's high watermark ──────

# go-p2p hardcodes connmgr low=100 high=400 grace=20s. Allowlisted clients can exceed 400, so
# this holds CEILING_PER_PROBE connections from each of 4 shared-IP clients and samples the
# target's connected-peer count to show the rise and any trim back toward the low watermark.
ceiling() {
    need docker; need jq; need curl
    docker info >/dev/null 2>&1 || die "Docker daemon is not running"
    local per="${CEILING_PER_PROBE:-250}" n="${CEILING_CLIENTS:-4}" ts out peer_id target i names=() t0 count
    ts="$(date +%Y%m%d-%H%M%S)"; mkdir -p "${HERE}/results"; out="${HERE}/results/ceiling-${ts}.tsv"
    down; up_base
    [[ "${KEEP:-0}" == 1 ]] || trap down EXIT
    start_target allowlist
    peer_id="$(target_peer_id)"
    log "target ${peer_id}: $(target_limits_line)"
    target="/ip4/${TARGET_IP}/tcp/9171/p2p/${peer_id}"
    for i in $(seq 1 "${n}"); do
        docker run -d --name "cl-probe-${i}" --network container:cl-nat "${PROBE_IMAGE}" \
            -target "${target}" -max "${per}" -mode hold -label "probe-${i}" \
            -settle "${CEILING_SETTLE:-90s}" -hold 5s >/dev/null
        names+=("cl-probe-${i}")
    done
    printf 'elapsed_s\tpeers\n' > "${out}"
    t0="${SECONDS}"
    while docker ps -q --filter name=cl-probe- | grep -q .; do
        count="$(curl -s --max-time 3 "http://localhost:${HEALTH_PORT}/health" | jq '(.p2p.peers // []) | length' 2>/dev/null || echo NA)"
        printf '%s\t%s\n' "$(( SECONDS - t0 ))" "${count}" | tee -a "${out}" >&2
        sleep 3
    done
    for c in "${names[@]}"; do docker logs "${c}" 2>/dev/null | sed -n 's/^RESULT //p'; done \
        | jq -s '{attempted: (map(.attempted)|add), connected: (map(.connected)|add),
                  alive_after_settle: (map(.alive)|add), refused: (map(.refused)|add),
                  errors: (map(.errors|to_entries[])|group_by(.key)|map({(.[0].key): (map(.value)|add)})|add)}' \
        | tee "${out%.tsv}.json"
    log "trim log lines on target:"
    docker logs cl-target 2>&1 | grep -iE 'connmgr|grace period|open connection count' | tail -5 >&2 || true
    docker rm -f "${names[@]}" >/dev/null
    log "series: ${out}"
}

case "${1:-all}" in
    build) build ;;
    run)   run_matrix ;;
    all)   build; run_matrix ;;
    down)  down ;;
    ceiling) ceiling ;;
    *) die "usage: $0 build|run|all|ceiling|down" ;;
esac
