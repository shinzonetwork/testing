#!/usr/bin/env bash
set -euo pipefail

# ───────────────────────────────────────────────────────────────
# Shinzo E2E-multi: up to 3 generators ⇄ 3 hosts, full P2P mesh
#
# Measures libp2p traffic, CPU, memory, disk, lag and replication
# correctness while every node replicates a live chain under
# transaction load. Built to show the effect of pulling CARs on
# demand (defradb eca80c1f) instead of pushing one with every update.
#
# Usage:
#   ./run.sh build baseline|candidate   build test images (never pushed)
#       DEFRADB_REF=<git ref>  build against that commit of the local defradb
#                  checkout, or WORKTREE for its uncommitted tracked changes
#                  checkout (DEFRADB_SRC, default ../../defradb) instead of the
#                  version pinned in go.mod. Client code comes from the working
#                  trees, so two such images differ only in defradb.
#       baseline:  shinzo-{indexer,host}:baseline from each client repo's
#                  BASELINE_REF (default HEAD), via git archive
#       candidate: shinzo-{indexer,host}:candidate from the working trees
#   ./run.sh cycle                      promote :candidate to :baseline (old one
#                                       kept as :baseline-prev), then build a new candidate
#   ./run.sh run [label]                one measured run → results/<label>.json
#   ./run.sh ab                         baseline run, candidate run, compare
#                                       (baseline: BASELINE_GEN_IMAGE / BASELINE_HOST_IMAGE,
#                                       default shinzo-{indexer,host}:baseline)
#   ./run.sh compare A.json B.json      print metrics side by side; exit 1 unless
#                                       both pass and B's mesh bytes/block is
#                                       MIN_REDUCTION_PCT lower
#   ./run.sh compare-md A.json B.json   same table as markdown, never fails
#   ./run.sh car-md RESULT.json         CAR exchange table for one run, as markdown
#   ./run.sh down                       tear everything down
#
# Run configuration (env):
#   GENS=3 HOSTS=3            topology, 1–3 each; every node dials every other
#   SCENARIO=steady           steady | restart (last host restarted mid-window)
#                             | freeze (last host paused FREEZE_SECONDS)
#   GEN_IMAGE / HOST_IMAGE    images for all generators / hosts
#                             (default shinzo-{indexer,host}:candidate)
#   GEN_n_IMAGE / HOST_n_IMAGE  per-node override, for mixed-version meshes
#   MEASURE_SECONDS=180       measured window (multiple of the 30s p2p stats interval)
#   WARMUP_SECONDS=30         load runs this long before the window opens
#   LOAD_ACCOUNTS=4 LOAD_INTERVAL=0.2   load: accounts × (1/interval) tx/s
#   GEN_ACCEPT_INCOMING=false let generators merge from each other
#   NOISE_PCT=5               deltas smaller than this are reported as "same"
#   MIN_REDUCTION_PCT=0       compare threshold on mesh bytes/block
#   KEEP=1                    leave containers up after a run
#
# Requirements: docker (compose v2), curl, jq, awk, git
# ───────────────────────────────────────────────────────────────

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAP_DIR="$(cd "${DIR}/../.." && pwd)"
COMPOSE="docker compose -f ${DIR}/docker-compose.yml"
RUN_DIR="${DIR}/.run"
RESULTS_DIR="${RESULTS_DIR:-${DIR}/results}"

GENS="${GENS:-3}"
HOSTS="${HOSTS:-3}"
SCENARIO="${SCENARIO:-steady}"
MEASURE_SECONDS="${MEASURE_SECONDS:-180}"
WARMUP_SECONDS="${WARMUP_SECONDS:-30}"
PEER_TIMEOUT="${PEER_TIMEOUT:-180}"
MESH_TIMEOUT="${MESH_TIMEOUT:-90}"
CATCHUP_TIMEOUT="${CATCHUP_TIMEOUT:-180}"
PARITY_TIMEOUT="${PARITY_TIMEOUT:-60}"
# DefraDB reports p2p counters every 30s and resets them; nothing is flushed at
# shutdown, so the last interval is lost unless we wait past it before scraping.
STATS_DRAIN_SECONDS="${STATS_DRAIN_SECONDS:-35}"
LAG_TOLERANCE="${LAG_TOLERANCE:-2}"
FREEZE_SECONDS="${FREEZE_SECONDS:-20}"
NOISE_PCT="${NOISE_PCT:-5}"
MIN_REDUCTION_PCT="${MIN_REDUCTION_PCT:-0}"
CANDIDATE_TAG="${CANDIDATE_TAG:-candidate}"
export LOAD_ACCOUNTS="${LOAD_ACCOUNTS:-4}"
export LOAD_INTERVAL="${LOAD_INTERVAL:-0.2}"
KEEP="${KEEP:-0}"
LAST_PASS=false

ALL_NODES=(gen-1 gen-2 gen-3 host-1 host-2 host-3)
ALL_IPS=(172.30.0.11 172.30.0.12 172.30.0.13 172.30.0.21 172.30.0.22 172.30.0.23)
ALL_PORTS=(18081 18082 18083 18091 18092 18093)
COLLECTIONS="Ethereum__Mainnet__Block Ethereum__Mainnet__Transaction Ethereum__Mainnet__Log"
STATS_KEYS="msgsIn|docsMerged|docsSkipped|docsDropped|carImports|carImportFailed|carBuilt|carFailed|carFetched|carFetchMissed|carCacheHits|syncDAGCalls|droppedOverBudget|droppedQueueFull"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[e2e-multi]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[e2e-multi]${NC} $*" >&2; }
die()  { echo -e "${RED}[e2e-multi FAIL]${NC} $*" >&2; exit 1; }

role_of() { case "$1" in gen-*) echo generator ;; *) echo host ;; esac; }
anvil()   { docker exec e2e-multi-anvil cast "$@"; }
num()     { [[ "$1" =~ ^[0-9]+$ ]] && echo "$1" || echo 0; }

# Selects the NODES / IPS / PORTS of the GENS × HOSTS topology.
select_topology() {
    [[ "${GENS}" =~ ^[1-3]$ && "${HOSTS}" =~ ^[1-3]$ ]] || die "GENS and HOSTS must be 1–3"
    NODES=(); IPS=(); PORTS=()
    local i
    for i in $(seq 0 $(( GENS - 1 ))) $(seq 3 $(( HOSTS + 2 ))); do
        NODES+=("${ALL_NODES[$i]}"); IPS+=("${ALL_IPS[$i]}"); PORTS+=("${ALL_PORTS[$i]}")
    done
}

# Resolves GEN_n_IMAGE / HOST_n_IMAGE for every node, defaulting to GEN_IMAGE /
# HOST_IMAGE, and exports them for compose.
resolve_images() {
    local n v
    for n in 1 2 3; do
        v="GEN_${n}_IMAGE";  export "${v}=${!v:-${GEN_IMAGE}}"
        v="HOST_${n}_IMAGE"; export "${v}=${!v:-${HOST_IMAGE}}"
    done
}

node_image() { local v; v="$(echo "$1" | tr 'a-z-' 'A-Z_' | sed 's/_\([0-9]\)$/_\1_IMAGE/')"; echo "${!v}"; }

dc() {
    $COMPOSE "$@" >>"${RUN_DIR}/compose.log" 2>&1 \
        || { tail -20 "${RUN_DIR}/compose.log" >&2; die "docker compose $* failed"; }
}

teardown() {
    $COMPOSE --profile load down -v --remove-orphans >/dev/null 2>&1 || true
    rm -rf "${RUN_DIR}"
}

on_exit() {
    if [[ "${KEEP}" == "1" ]]; then
        warn "KEEP=1: containers left running. Stop with: $0 down"
    else
        teardown
    fi
}

health() { curl -s --max-time 5 "http://localhost:$1/health" 2>/dev/null || echo '{}'; }

peer_id() {
    health "$1" | jq -r '
        .p2p.self.id // .p2p.self.peer_id // .p2p.self.peerID //
        .p2p.peer_id // .peer_id // .peerID // .peerInfo.id // empty' 2>/dev/null || true
}

peer_count()    { num "$(health "$1" | jq -r '(.p2p.peers // []) | length' 2>/dev/null)"; }
current_block() { num "$(health "$1" | jq -r '.current_block // .currentBlock // .block_height // 0' 2>/dev/null)"; }

wait_peer_id() {
    local name="$1" port="$2" id="" start="${SECONDS}"
    while [[ -z "${id}" ]]; do
        if (( SECONDS - start > PEER_TIMEOUT )); then
            $COMPOSE logs --tail=80 "${name}" >&2
            die "${name}: no peer ID after ${PEER_TIMEOUT}s"
        fi
        sleep 2
        id="$(peer_id "${port}")"
    done
    echo "${id}"
}

# Prints "rx tx cpu_usec" for a node: byte counters of its p2p-net interface
# (read from a busybox container sharing the node's network namespace, so it
# works whatever the node image ships with) and its cgroup CPU time.
counters() {
    local name="$1" ip="$2" net cpu
    net="$(docker run --rm -e IP="${ip}" --network "container:e2e-multi-${name}" busybox sh -c '
        ifc=$(ip -o -4 addr show | awk -v ip="$IP/" "index(\$4, ip)==1 {print \$2}")
        sed "s/:/ /" /proc/net/dev | awk -v i="$ifc" "\$1==i {print \$2, \$10}"' 2>/dev/null || true)"
    cpu="$(docker exec "e2e-multi-${name}" sh -c 'awk "/^usage_usec/ {print \$2}" /sys/fs/cgroup/cpu.stat' 2>/dev/null || true)"
    echo "${net:-0 0} $(num "${cpu}")"
}

# Writes "name rx tx cpu_usec" for every node to $1, sampling in parallel.
snapshot() {
    local out="$1" i
    for i in "${!NODES[@]}"; do
        ( echo "${NODES[$i]} $(counters "${NODES[$i]}" "${IPS[$i]}")" > "${out}.${i}" ) &
    done
    wait
    cat "${out}".[0-9] > "${out}"
    rm -f "${out}".[0-9]
}

# A restart resets a node's interface and cgroup counters. Shifting its window
# start by (pre - post) keeps (t1 - t0) equal to the traffic across the restart.
rebase() {
    local name="$1" pre="$2" post="$3" f="${RUN_DIR}/snap0"
    awk -v n="${name}" -v pre="${pre}" -v post="${post}" '
        BEGIN { split(pre, a, " "); split(post, b, " ") }
        $1 == n { printf "%s %.0f %.0f %.0f\n", n, $2 - a[1] + b[1], $3 - a[2] + b[2], $4 - a[3] + b[3]; next }
        { print }' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
}

# Sums the counters from the node's "p2p stats" log lines in [since, until] and
# prints them as a JSON object. Handles both key=N and "key": N log formats.
p2p_stats() {
    docker logs --since "$2" --until "$3" "e2e-multi-$1" 2>&1 \
        | { grep 'p2p stats' || true; } \
        | grep -oE "\"?(${STATS_KEYS})\"?[=:] ?[0-9]+" \
        | tr -d '"' | tr ':=' '  ' \
        | awk '{s[$1]+=$2} END {for (k in s) printf "%s %.0f\n", k, s[k]}' \
        | jq -Rn '[inputs | split(" ") | {(.[0]): (.[1] | tonumber)}] | add // {}'
}

# Prints {"<collection>": count, ...} for a node, or nulls when unavailable.
# Counts _docIDs (this defradb has no _count), querying DefraDB on whichever
# address it listens on: loopback on hosts, the first interface on generators.
doc_counts() {
    local name="$1" c q f out="{}" n addr
    addr="$(docker run --rm --network "container:e2e-multi-${name}" busybox netstat -ltn 2>/dev/null \
        | awk '$4 ~ /:9181$/ {print $4; exit}' | sed -e 's/^0\.0\.0\.0:/127.0.0.1:/' -e 's/^:::/127.0.0.1:/')"
    for c in ${COLLECTIONS}; do
        # Genesis is indexed before any host joins and pubsub does not backfill,
        # so only blocks mined during the run are compared.
        f=""; [[ "${c}" == *__Block ]] && f="(filter: {number: {_gt: 0}})"
        q="{\"query\":\"query { ${c}${f} { _docID } }\"}"
        n="$(docker run --rm --network "container:e2e-multi-${name}" busybox \
            wget -qO- -T 30 --header 'Content-Type: application/json' --post-data "${q}" \
            "http://${addr:-127.0.0.1:9181}/api/v0/graphql" 2>/dev/null \
            | jq -r --arg c "${c}" '.data[$c] | if type == "array" then length else empty end' 2>/dev/null || true)"
        out="$(jq -c --arg c "${c#Ethereum__Mainnet__}" --arg n "${n}" \
            '. + {($c): (if $n == "" then null else ($n | tonumber) end)}' <<< "${out}")"
    done
    echo "${out}"
}

# Whole-run sums of the "p2p stats" counters, for the CAR diagnostics. Counters
# reset every interval, so totals need every line, not just the measured window.
p2p_stats_all() {
    docker logs "e2e-multi-$1" 2>&1 \
        | { grep 'p2p stats' || true; } \
        | grep -oE "\"?(${STATS_KEYS})\"?[=:] ?[0-9]+" \
        | tr -d '"' | tr ':=' '  ' \
        | awk '{s[$1]+=$2} END {for (k in s) printf "%s %.0f\n", k, s[k]}' \
        | jq -Rn '[inputs | split(" ") | {(.[0]): (.[1] | tonumber)}] | add // {}'
}

# Sums one reason line ("CAR fetch outcomes" / "CAR serve outcomes") over the whole
# run. These lines are only logged in intervals where something happened, so an
# absent line means zero, not a parse failure.
outcomes() {
    docker logs "e2e-multi-$1" 2>&1 \
        | { grep "$2" || true; } \
        | grep -oE '[A-Za-z]+=[0-9]+' \
        | awk -F= '{s[$1]+=$2} END {for (k in s) printf "%s %.0f\n", k, s[k]}' \
        | jq -Rn '[inputs | split(" ") | {(.[0]): (.[1] | tonumber)}] | add // {}'
}

# Total transactions mined from the load accounts (their summed nonces).
load_nonces() {
    local total=0 addr
    for addr in $(anvil rpc eth_accounts | tr -d '[]" ' | tr ',' '\n' | sed -n "2,$((LOAD_ACCOUNTS + 1))p"); do
        total=$(( total + $(anvil nonce "${addr}") ))
    done
    echo "${total}"
}

# Largest gap between the chain head and the slowest reachable host.
host_lag() {
    local head i b min=""
    head="$(anvil block-number)"
    for i in "${!NODES[@]}"; do
        [[ "$(role_of "${NODES[$i]}")" == host ]] || continue
        b="$(current_block "${PORTS[$i]}")"
        (( b > 0 )) || continue  # down (restarting / frozen): not a lag sample
        [[ -z "${min}" ]] || (( b < min )) && min="${b}"
    done
    echo $(( head - ${min:-${head}} ))
}

# Docker Desktop's containerd store sometimes loses a tag→image reference: the tag is listed by
# `docker image ls` but `docker image inspect <tag>` reports it missing. Re-tagging from the image
# ID repairs it, so a stale index does not fail a run.
image_exists() {
    local tag="$1" id
    docker image inspect "${tag}" >/dev/null 2>&1 && return 0
    id="$(docker image ls --format '{{.Repository}}:{{.Tag}} {{.ID}}' | awk -v t="${tag}" '$1 == t {print $2; exit}')"
    [[ -n "${id}" ]] || return 1
    warn "repairing stale tag reference for ${tag}"
    docker tag "${id}" "${tag}" >/dev/null 2>&1 && docker image inspect "${tag}" >/dev/null 2>&1
}

require_image() {
    image_exists "$1" || die "image $1 not found. Build it first: $0 build baseline|candidate"
}

# ── one measured run ─────────────────────────────────────────
run_one() {
    local label="$1"
    export GEN_IMAGE="$2" HOST_IMAGE="$3"
    local out="${RESULTS_DIR}/${label}.json" logs="${RESULTS_DIR}/${label}-logs"
    local i n name ip port id peers

    select_topology
    resolve_images
    for name in "${NODES[@]}"; do require_image "$(node_image "${name}")"; done
    docker image inspect busybox >/dev/null 2>&1 || docker pull -q busybox >/dev/null
    log "═══ run '${label}': ${GENS} generators × ${HOSTS} hosts, scenario=${SCENARIO}"
    for name in "${NODES[@]}"; do log "  ${name}: $(node_image "${name}")"; done

    teardown
    mkdir -p "${RUN_DIR}" "${RESULTS_DIR}"
    rm -rf "${logs}"

    log "Starting anvil (mining paused)..."
    dc up -d --wait anvil

    # Each node bootstraps to every node started before it → full mesh.
    local addrs=()
    for i in "${!NODES[@]}"; do
        name="${NODES[$i]}"; ip="${IPS[$i]}"; port="${PORTS[$i]}"
        if [[ "$(role_of "${name}")" == generator ]]; then
            peers="[]"
            (( ${#addrs[@]} > 0 )) && peers="[$(printf '"%s",' "${addrs[@]}" | sed 's/,$//')]"
            sed -e "s|__LISTEN_IP__|${ip}|" -e "s|__BOOTSTRAP_PEERS__|${peers}|" \
                "${DIR}/generator.template.yaml" > "${RUN_DIR}/${name}.yaml"
        else
            export "HOST_${name#host-}_PEERS=$(IFS=,; echo "${addrs[*]}")"
        fi
        dc up -d --no-deps "${name}"
        id="$(wait_peer_id "${name}" "${port}")"
        log "  ${name} up: ${id} (dialed ${#addrs[@]} peers)"
        addrs+=("/ip4/${ip}/tcp/9171/p2p/${id}")
    done

    local want=$(( ${#NODES[@]} - 1 )) mesh_ok=true mesh_json ok c start
    log "Waiting for full mesh (${want} peers per node)..."
    start="${SECONDS}"
    while :; do
        mesh_json="{}"; ok=1
        for i in "${!NODES[@]}"; do
            c="$(peer_count "${PORTS[$i]}")"
            mesh_json="$(jq -c --arg n "${NODES[$i]}" --argjson c "${c}" '. + {($n): $c}' <<< "${mesh_json}")"
            (( c >= want )) || ok=0
        done
        (( ok == 1 )) && break
        if (( SECONDS - start > MESH_TIMEOUT )); then
            mesh_ok=false
            warn "  mesh incomplete after ${MESH_TIMEOUT}s"
            break
        fi
        sleep 3
    done
    log "  peers: ${mesh_json}"

    log "Starting 1s interval mining and tx load (${LOAD_ACCOUNTS} accounts, every ${LOAD_INTERVAL}s)..."
    anvil rpc evm_setIntervalMining 1 >/dev/null
    dc --profile load up -d --no-deps loadgen
    log "Warming up ${WARMUP_SECONDS}s..."
    sleep "${WARMUP_SECONDS}"

    # ── measured window ──
    local t0 t1 head0 head1 nonce0 nonce1 lag max_lag=0 last_log=0 event_done=0
    local target_node="host-${HOSTS}" target_port="${ALL_PORTS[$(( HOSTS + 2 ))]}"
    local target_ip="${ALL_IPS[$(( HOSTS + 2 ))]}" pre post
    t0="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    head0="$(anvil block-number)"; nonce0="$(load_nonces)"
    snapshot "${RUN_DIR}/snap0"
    log "Measuring for ${MEASURE_SECONDS}s from block ${head0}..."
    start="${SECONDS}"
    while (( SECONDS - start < MEASURE_SECONDS )); do
        sleep 5
        lag="$(host_lag)"; (( lag > max_lag )) && max_lag="${lag}"
        if (( SECONDS - start - last_log >= 30 )); then
            last_log=$(( SECONDS - start ))
            log "  t+${last_log}s chain=$(anvil block-number) host lag=${lag} (max ${max_lag})"
        fi
        if (( event_done == 0 )); then
            if [[ "${SCENARIO}" == restart ]] && (( SECONDS - start >= MEASURE_SECONDS / 2 )); then
                event_done=1
                log "  ⟳ restarting ${target_node}"
                pre="$(counters "${target_node}" "${target_ip}")"
                docker restart "e2e-multi-${target_node}" >/dev/null
                wait_peer_id "${target_node}" "${target_port}" >/dev/null
                post="$(counters "${target_node}" "${target_ip}")"
                rebase "${target_node}" "${pre}" "${post}"
                log "  ⟳ ${target_node} back after restart"
            elif [[ "${SCENARIO}" == freeze ]] && (( SECONDS - start >= MEASURE_SECONDS / 3 )); then
                event_done=1
                log "  ❄ freezing ${target_node} for ${FREEZE_SECONDS}s"
                docker pause "e2e-multi-${target_node}" >/dev/null
                sleep "${FREEZE_SECONDS}"
                docker unpause "e2e-multi-${target_node}" >/dev/null
            fi
        fi
    done
    snapshot "${RUN_DIR}/snap1"
    head1="$(anvil block-number)"; nonce1="$(load_nonces)"
    t1="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # ── replication: every node must reach the head ──
    dc --profile load stop loadgen
    local load_stopped="${SECONDS}"
    anvil rpc evm_setIntervalMining 0 >/dev/null
    local target replicated=true catchup blocks_json b
    target="$(anvil block-number)"
    log "Load stopped at block ${target}; waiting for every node to catch up..."
    start="${SECONDS}"
    while :; do
        ok=1; blocks_json="{}"
        for i in "${!NODES[@]}"; do
            b="$(current_block "${PORTS[$i]}")"
            blocks_json="$(jq -c --arg n "${NODES[$i]}" --argjson b "${b}" '. + {($n): $b}' <<< "${blocks_json}")"
            (( b >= target - LAG_TOLERANCE )) || ok=0
        done
        catchup=$(( SECONDS - start ))
        (( ok == 1 )) && break
        if (( catchup > CATCHUP_TIMEOUT )); then
            replicated=false
            warn "  not all nodes reached block ${target} within ${CATCHUP_TIMEOUT}s"
            break
        fi
        sleep 2
    done
    log "  node blocks after ${catchup}s: ${blocks_json}"

    # ── parity: every node holds the same documents ──
    local parity=null parity_json dir="${RUN_DIR}/counts"
    log "Checking document parity (${COLLECTIONS// /, })..."
    mkdir -p "${dir}"
    start="${SECONDS}"
    while :; do
        for name in "${NODES[@]}"; do ( doc_counts "${name}" > "${dir}/${name}" ) & done
        wait
        parity_json="$(for name in "${NODES[@]}"; do jq -c --arg n "${name}" '{($n): .}' "${dir}/${name}"; done | jq -sc 'add')"
        parity="$(jq -r 'if [.[][] | select(. == null)] | length > 0 then "null"
            elif ([.[]] | unique | length) == 1 then "true" else "false" end' <<< "${parity_json}")"
        [[ "${parity}" == false ]] || break
        (( SECONDS - start > PARITY_TIMEOUT )) && break
        sleep 5
    done
    case "${parity}" in
        true)  log "  parity ok: $(jq -c '[.[]][0]' <<< "${parity_json}")" ;;
        false) warn "  parity MISMATCH: ${parity_json}" ;;
        *)     warn "  parity unknown (GraphQL count unavailable): ${parity_json}" ;;
    esac

    # ── lens views: every host must return rows from at least one view ──
    # A view is query + SDL + transform. Which views exist comes from ShinzoHub, so they are
    # read from DefraDB's collection descriptions (a view is a collection with a Query) rather
    # than hard-coded, and the query's source and filter are recorded, since the filter is what
    # decides whether this run's data can match. A view has no _docID; rows are counted with
    # __typename, which every object type has.
    local views_json='{}' vdir="${RUN_DIR}/views" vnames vn h resp n
    mkdir -p "${vdir}/q"
    docker run --rm --network "container:e2e-multi-host-1" busybox \
        wget -qO- -T 20 http://127.0.0.1:9181/api/v0/collections > "${vdir}/collections.json" 2>/dev/null || true
    vnames="$(jq -r '(if type == "array" then . else [.] end) | .[] | select(.Query != null) | .Name' \
        "${vdir}/collections.json" 2>/dev/null | sort -u)"
    if [[ -n "${vnames}" ]]; then
        for vn in ${vnames}; do
            printf '{"query":"query { %s { __typename } }"}' "${vn}" > "${vdir}/q/${vn}.json"
        done
        views_json="$(jq -c '(if type == "array" then . else [.] end) | map(select(.Query != null))
            | map({key: .Name, value: {
                source: .Query.Query.Name,
                filter: (.Query.Query.Filter.Conditions // null),
                selects: [.Query.Query.Fields[]?.Name],
                rows: {}}}) | from_entries' "${vdir}/collections.json")"
        for h in "${NODES[@]}"; do
            [[ "$(role_of "${h}")" == host ]] || continue
            docker run --rm -v "${vdir}/q:/q:ro" --network "container:e2e-multi-${h}" busybox sh -c '
                for f in /q/*.json; do
                    n=${f#/q/}; n=${n%.json}
                    printf "%s\t" "$n"
                    wget -qO- -T 30 --header "Content-Type: application/json" --post-file "$f" \
                        http://127.0.0.1:9181/api/v0/graphql 2>/dev/null | tr -d "\n" || true
                    echo
                done' > "${vdir}/${h}.tsv" 2>/dev/null || true
            while IFS=$'\t' read -r vn resp; do
                n="$(jq -r --arg v "${vn}" '.data[$v] | if type == "array" then length else empty end' <<< "${resp}" 2>/dev/null)"
                views_json="$(jq -c --arg v "${vn}" --arg h "${h}" --arg n "${n}" \
                    '.[$v].rows[$h] = (if $n == "" then null else ($n | tonumber) end)' <<< "${views_json}")"
            done < "${vdir}/${h}.tsv"
        done
        log "  views: $(jq -r 'to_entries | map("\(.key | .[0:32])=\([.value.rows[]] | map(. // "?" | tostring) | join("/"))") | join("  ")' <<< "${views_json}")"
    else
        warn "  no lens views registered — hosts could not reach ShinzoHub, so views are unchecked"
    fi

    # ── drain: let the last stats interval be logged before scraping ──
    local drain=$(( STATS_DRAIN_SECONDS - (SECONDS - load_stopped) ))
    if (( drain > 0 )); then
        log "Waiting ${drain}s for the final p2p stats interval..."
        sleep "${drain}"
    fi

    # ── collect ──
    local nodes_file="${RUN_DIR}/nodes.jsonl" rx0 tx0 cpu0 rx1 tx1 cpu1 mem disk images_json="{}"
    : > "${nodes_file}"
    mkdir -p "${logs}"
    for name in "${NODES[@]}"; do
        read -r _ rx0 tx0 cpu0 < <(grep "^${name} " "${RUN_DIR}/snap0")
        read -r _ rx1 tx1 cpu1 < <(grep "^${name} " "${RUN_DIR}/snap1")
        mem="$(num "$(docker exec "e2e-multi-${name}" sh -c 'cat /sys/fs/cgroup/memory.peak 2>/dev/null || cat /sys/fs/cgroup/memory.current' 2>/dev/null || true)")"
        disk="$(num "$(docker exec "e2e-multi-${name}" du -sb /app/.defra 2>/dev/null | awk '{print $1}' || true)")"
        images_json="$(jq -c --arg n "${name}" --arg i "$(node_image "${name}")" '. + {($n): $i}' <<< "${images_json}")"
        jq -nc --arg name "${name}" --arg role "$(role_of "${name}")" --arg image "$(node_image "${name}")" \
            --argjson rx $(( rx1 - rx0 )) --argjson tx $(( tx1 - tx0 )) \
            --argjson cpu_usec $(( cpu1 - cpu0 )) --argjson mem "${mem}" --argjson disk "${disk}" \
            --argjson stats "$(p2p_stats "${name}" "${t0}" "${t1}")" \
            --argjson stats_run "$(p2p_stats_all "${name}")" \
            --argjson fetch "$(outcomes "${name}" 'CAR fetch outcomes')" \
            --argjson serve "$(outcomes "${name}" 'CAR serve outcomes')" \
            '{name: $name, role: $role, image: $image, rx: $rx, tx: $tx,
              cpu_sec: ($cpu_usec / 1e6), mem_peak: $mem, disk: $disk, stats: $stats,
              stats_run: $stats_run, fetch_outcomes: $fetch, serve_outcomes: $serve}' >> "${nodes_file}"
        docker logs "e2e-multi-${name}" > "${logs}/${name}.log" 2>&1 || true
    done

    jq -n \
        --arg label "${label}" --arg scenario "${SCENARIO}" \
        --argjson topology "{\"gens\": ${GENS}, \"hosts\": ${HOSTS}}" \
        --argjson images "${images_json}" \
        --arg t0 "${t0}" --arg t1 "${t1}" --argjson window "${MEASURE_SECONDS}" \
        --argjson load "{\"accounts\": ${LOAD_ACCOUNTS}, \"interval\": \"${LOAD_INTERVAL}\"}" \
        --argjson blocks $(( head1 - head0 )) --argjson txs $(( nonce1 - nonce0 )) \
        --argjson max_lag "${max_lag}" --argjson catchup "${catchup}" \
        --argjson mesh_ok "${mesh_ok}" --argjson mesh "${mesh_json}" \
        --argjson replicated "${replicated}" --argjson target "${target}" --argjson node_blocks "${blocks_json}" \
        --argjson parity "${parity}" --argjson counts "${parity_json}" \
        --argjson views "${views_json}" \
        --slurpfile nodes "${nodes_file}" '
        def total(f): map(f) | add // 0;
        def per(n; d): if d > 0 then (n / d | floor) else null end;
        ($nodes | map(select(.role == "generator"))) as $gens |
        ($nodes | map(select(.role == "host"))) as $hosts |
        (reduce ($nodes[].stats | to_entries[]) as $e ({}; .[$e.key] += $e.value)) as $st |
        {
          label: $label, scenario: $scenario, topology: $topology, images: $images,
          window: {from: $t0, to: $t1, seconds: $window}, load: $load,
          blocks: $blocks, txs: $txs, max_lag_blocks: $max_lag, catchup_seconds: $catchup,
          mesh: $mesh, node_blocks: $node_blocks, target_block: $target, doc_counts: $counts,
          nodes: $nodes, stats_total: $st, views: $views,
          totals: {
            mesh_rx: ($nodes | total(.rx)), mesh_tx: ($nodes | total(.tx)),
            gen_rx: ($gens | total(.rx)), gen_tx: ($gens | total(.tx)),
            host_rx: ($hosts | total(.rx)), host_tx: ($hosts | total(.tx)),
            cpu_sec: ($nodes | total(.cpu_sec)),
            mem_peak_max: ($nodes | map(.mem_peak) | max),
            host_disk_avg: (($hosts | total(.disk)) / ($hosts | length) | floor)
          },
          checks: {
            mesh: $mesh_ok, replicated: $replicated, parity: $parity,
            no_drops: ((($st.droppedOverBudget // 0) + ($st.droppedQueueFull // 0)) == 0),
            no_import_failures: (($st.carImportFailed // 0) == 0),
            car_pull_used: (if [$hosts[].stats | has("carFetched")] | any
                            then ($hosts | total(.stats.carFetched // 0)) > 0 else null end)
          }
        }
        | .nodes = (.nodes | map(. + {car: (
            (.stats_run.carFetched // null) as $f | (.stats_run.carFetchMissed // null) as $m |
            {
              fetched: $f, missed: $m,
              syncDAG: (.stats_run.syncDAGCalls // 0),
              built: (.stats_run.carBuilt // 0),
              cacheHits: (.stats_run.carCacheHits // 0),
              imports: (.stats_run.carImports // 0),
              importFailed: (.stats_run.carImportFailed // 0),
              miss_rate: (if $f == null or $m == null or ($f + $m) == 0 then null
                          else ($m / ($f + $m) * 1000 | round / 1000) end),
              invariants: {
                # nothing else in a run starts a DAG walk
                missed_eq_syncdag: (if $m == null then null else ($m == (.stats_run.syncDAGCalls // 0)) end),
                # every fetched head came from the creator or the relay
                fetched_sum_matches: (if $f == null or ((.fetch_outcomes | length) == 0) then null
                    else (((.fetch_outcomes.creatorFetched // 0) + (.fetch_outcomes.relayFetched // 0)) == $f) end)
              }
            })}))
        | .checks.car_invariants = ([.nodes[] | select(.role == "host") | .car.invariants | to_entries[] | .value]
            | map(select(. != null)) | if length == 0 then null else all end)
        # null when no views were registered, so a hub outage does not fail the run
        | .checks.views_populated = (if ($views | length) == 0 then null else
            ([$views[].rows | keys[]] | unique) as $hs
            | [$hs[] as $h | ([$views[] | .rows[$h] // 0] | max) > 0] | all end)
        | .per_block = {
            mesh_bytes: per(.totals.mesh_rx; $blocks),
            host_rx_bytes: per(.totals.host_rx; $blocks),
            gen_tx_bytes: per(.totals.gen_tx; $blocks),
            cpu_ms: (if $blocks > 0 then (.totals.cpu_sec * 1000 / $blocks | round) else null end),
            host_disk_bytes: per(.totals.host_disk_avg; $target)
          }
        | .per_tx = {mesh_bytes: per(.totals.mesh_rx; $txs)}
        | .pass = (.checks.mesh and .checks.replicated and .checks.parity != false
                   and .checks.views_populated != false
                   and .checks.no_drops and .checks.no_import_failures
                   and (if $scenario == "steady" then .checks.car_invariants != false else true end))' > "${out}"

    report "${out}"
    log "Results: ${out}  (node logs: ${logs}/)"
    LAST_PASS="$(jq -r .pass "${out}")"
    [[ "${LAST_PASS}" == true ]] || warn "run '${label}' FAILED checks: $(jq -c .checks "${out}")"
}

JQ_HUMAN='def human: . as $b | if $b == null then "-"
    elif $b >= 1073741824 then "\($b / 1073741824 * 100 | floor / 100) GiB"
    elif $b >= 1048576 then "\($b / 1048576 * 100 | floor / 100) MiB"
    elif $b >= 1024 then "\($b / 1024 * 10 | floor / 10) KiB"
    else "\($b) B" end;'

report() {
    local f="$1"
    echo
    jq -r '"  \(.label): \(.topology.gens)g×\(.topology.hosts)h \(.scenario), \(.blocks) blocks, \(.txs) txs in \(.window.seconds)s — \(if .pass then "PASS" else "FAIL" end)"' "${f}"
    echo
    jq -r "${JQ_HUMAN}"'
        (["node", "image", "p2p_rx", "p2p_tx", "rx/blk", "tx/blk", "cpu_s", "mem_peak", "disk", "msgsIn", "carImports", "carFetched", "carFetchMissed", "carCacheHits", "syncDAG"] | @tsv),
        (.blocks as $n | .nodes[] | [.name, (.image | split(":") | last), (.rx | human), (.tx | human),
            (if $n > 0 then (.rx / $n | floor | human) else "-" end),
            (if $n > 0 then (.tx / $n | floor | human) else "-" end),
            (.cpu_sec * 10 | round / 10), (.mem_peak | human), (.disk | human),
            (.stats.msgsIn // 0), (.stats.carImports // 0), (.stats.carFetched // "-"),
            (.stats.carFetchMissed // "-"), (.stats.carCacheHits // "-"), (.stats.syncDAGCalls // 0)] | @tsv)' "${f}" \
        | column -t -s $'\t' | sed 's/^/  /'
    echo
    car_report "${f}"
    jq -r "${JQ_HUMAN}"'
        "  mesh bytes/block:  \(.per_block.mesh_bytes | human)   (host rx \(.per_block.host_rx_bytes | human), gen tx \(.per_block.gen_tx_bytes | human))",
        "  mesh bytes/tx:     \(.per_tx.mesh_bytes | human)",
        "  cpu/block:         \(.per_block.cpu_ms) ms (all nodes)",
        "  max host lag:      \(.max_lag_blocks) blocks, catch-up \(.catchup_seconds)s",
        "  checks:            \(.checks | to_entries | map("\(.key)=\(.value)") | join(" "))"' "${f}"
    echo
}

# Rows of [metric, baseline, candidate, delta, verdict]; lower is better for
# every metric. Deltas under NOISE_PCT are "same".
JQ_COMPARE="${JQ_HUMAN}"'
    $a[0] as $a | $b[0] as $b |
    def perblk($r; k): if $r.blocks > 0 then (($r.stats_total[k] // null) | if . == null then null else (. / $r.blocks * 100 | round / 100) end) else null end;
    def show(kind): if . == null then "-" elif kind == "bytes" then human else tostring end;
    def verdict(x; y): if x == null or y == null then "n/a"
        elif x == 0 and y == 0 then "same"
        elif x == 0 then "worse"
        else ((y - x) / x * 100) as $d |
            if ($d | fabs) < $noise then "same" elif $d < 0 then "better" else "worse" end end;
    def delta(x; y): if x == null or y == null or x == 0 then "-"
        else "\(if y > x then "+" else "" end)\(((y - x) / x * 1000 | round) / 10)%" end;
    [ ["mesh bytes/block",      $a.per_block.mesh_bytes,      $b.per_block.mesh_bytes,      "bytes"],
      ["host rx bytes/block",   $a.per_block.host_rx_bytes,   $b.per_block.host_rx_bytes,   "bytes"],
      ["gen tx bytes/block",    $a.per_block.gen_tx_bytes,    $b.per_block.gen_tx_bytes,    "bytes"],
      ["mesh bytes/tx",         $a.per_tx.mesh_bytes,         $b.per_tx.mesh_bytes,         "bytes"],
      ["cpu ms/block",          $a.per_block.cpu_ms,          $b.per_block.cpu_ms,          "num"],
      ["peak memory (max node)", $a.totals.mem_peak_max,      $b.totals.mem_peak_max,       "bytes"],
      ["host disk/block",       $a.per_block.host_disk_bytes, $b.per_block.host_disk_bytes, "bytes"],
      ["max host lag (blocks)", $a.max_lag_blocks,            $b.max_lag_blocks,            "num"],
      ["catch-up seconds",      $a.catchup_seconds,           $b.catchup_seconds,           "num"],
      ["msgsIn/block",          perblk($a; "msgsIn"),         perblk($b; "msgsIn"),         "num"],
      ["carImports/block",      perblk($a; "carImports"),     perblk($b; "carImports"),     "num"],
      ["syncDAG/block",         perblk($a; "syncDAGCalls"),   perblk($b; "syncDAGCalls"),   "num"],
      ["carFetchMissed/block",  perblk($a; "carFetchMissed"), perblk($b; "carFetchMissed"), "num"]
    ] | map(. as $row | [$row[0], ($row[1] | show($row[3])), ($row[2] | show($row[3])),
                         delta($row[1]; $row[2]), verdict($row[1]; $row[2])])
    | ([["metric", $a.label, $b.label, "delta", "verdict"]] + .
       + [["checks pass", ($a.pass | tostring), ($b.pass | tostring), "-",
           (if $a.pass and ($b.pass | not) then "REGRESSION" elif $b.pass then "ok" else "both fail" end)]])'


# CAR exchange, summed over the whole run: who served each head, who refused, and
# how often a head fell back to a DAG walk. Silent on images without the counters.
JQ_CAR_ROWS='(["node", "carFetched", "carMissed", "miss%", "syncDAG", "carBuilt", "cacheHits", "imports", "invariants"] | @tsv),
    (.nodes[] | [.name, (.car.fetched // "-"), (.car.missed // "-"),
        (if .car.miss_rate == null then "-" else ((.car.miss_rate * 100 | round | tostring) + "%") end),
        .car.syncDAG, .car.built, .car.cacheHits, .car.imports,
        (.car.invariants | to_entries |
            if (map(select(.value != null)) | length) == 0 then "-"
            elif (map(select(.value == false)) | length) == 0 then "ok"
            else "FAILED " + (map(select(.value == false) | .key) | join(",")) end)] | @tsv)'

JQ_CAR_DIAGNOSIS='
    ([.nodes[] | select(.role == "host") | .car.missed // 0] | add // 0) as $missed |
    ([.nodes[] | select(.role == "host") | .car.fetched // 0] | add // 0) as $fetched |
    ([.nodes[] | (.fetch_outcomes.creatorRequestFailed // 0) + (.fetch_outcomes.creatorBackoff // 0)] | add // 0) as $creator |
    ([.nodes[] | (.serve_outcomes.notHeld // 0) + (.serve_outcomes.noAccess // 0)] | add // 0) as $refused |
    ([.nodes[] | .fetch_outcomes.relayNotServed // 0] | add // 0) as $relay |
    [ (if $fetched > 0 and $missed == 0 then "every needed head was served by a peer — no DAG-walk fallbacks" else empty end),
      (if $missed > 0 then "\($missed) heads fell back to a DAG walk (miss rate \(($missed / ($missed + $fetched) * 100) | round)%)" else empty end),
      (if $creator > 0 then "creatorRequestFailed/creatorBackoff=\($creator): a host cannot reach the creator directly — check its connections and peerstore addresses" else empty end),
      (if $refused > 0 then "serve notHeld/noAccess=\($refused): the peer asked did not hold the requested CIDs, or refused them" else empty end),
      (if $relay > 0 then "relayNotServed=\($relay): expected — relays often have not stored the head when asked" else empty end) ] | .[]'

car_report() {
    local f="$1"
    jq -e '[.nodes[] | .car.fetched] | map(select(. != null)) | length > 0' "${f}" >/dev/null 2>&1 || return 0
    echo "  CAR exchange (whole run):"
    jq -r "${JQ_CAR_ROWS}" "${f}" | column -t -s $'\t' | sed 's/^/  /'
    echo
    jq -r '.nodes[] | select((.fetch_outcomes | length) > 0 or (.serve_outcomes | length) > 0) |
        "  \(.name) fetch: \(.fetch_outcomes | to_entries | map("\(.key)=\(.value)") | join(" "))",
        "  \(.name) serve: \(.serve_outcomes | to_entries | map("\(.key)=\(.value)") | join(" "))"' "${f}" \
        | grep -v ': $' || true
    echo
    jq -r "${JQ_CAR_DIAGNOSIS}" "${f}" | sed 's/^/  → /'
    echo
}

car_md() {
    local f="$1"
    jq -e '[.nodes[] | .car.fetched] | map(select(. != null)) | length > 0' "${f}" >/dev/null 2>&1 || return 0
    jq -r "${JQ_CAR_ROWS}" "${f}" | awk -F'\t' 'NR == 1 { n = NF; printf "| %s |\n|", $0; for (i = 0; i < n; i++) printf "---|"; printf "\n"; next } { printf "| %s |\n", $0 }' | sed 's/\t/ | /g'
    echo
    jq -r "${JQ_CAR_DIAGNOSIS}" "${f}" | sed 's/^/- /'
}

compare_rows() { jq -n --slurpfile a "$1" --slurpfile b "$2" --argjson noise "${NOISE_PCT}" "${JQ_COMPARE}"; }

compare() {
    local base="$1" cand="$2"
    [[ -f "${base}" && -f "${cand}" ]] || die "usage: $0 compare BASELINE.json CANDIDATE.json"
    echo
    compare_rows "${base}" "${cand}" | jq -r '.[] | @tsv' | column -t -s $'\t' | sed 's/^/  /'
    echo
    jq -en --slurpfile a "${base}" --slurpfile b "${cand}" --argjson min "${MIN_REDUCTION_PCT}" '
        $a[0] as $a | $b[0] as $b |
        $a.pass and $b.pass and ($b.per_block.mesh_bytes < $a.per_block.mesh_bytes * (1 - $min / 100))' >/dev/null \
        && log "PASS: ${cand##*/} mesh bytes/block is lower than ${base##*/} (threshold ${MIN_REDUCTION_PCT}%)" \
        || die "mesh bytes/block not reduced by more than ${MIN_REDUCTION_PCT}%, or a run failed its checks"
}

compare_md() {
    compare_rows "$1" "$2" | jq -r '
        (.[0] | "| " + join(" | ") + " |"), "|---|---:|---:|---:|---|",
        (.[1:][] | "| " + join(" | ") + " |")'
}

# Builds client images against a defradb commit from a local checkout, without
# touching the client repos. The build context gets the client working tree plus
# the defradb tree at that ref, wired together by a replace directive, so the
# only difference between two such images is the defradb code.
build_local_defradb() {
    local tag="$1" ref="$2" pair repo image ctx dfile sha
    local src="${DEFRADB_SRC:-${SNAP_DIR}/defradb}"
    [[ -d "${src}/.git" ]] || die "DEFRADB_SRC=${src} is not a git checkout"
    local archive_ref="${ref}"
    if [[ "${ref}" == WORKTREE ]]; then
        # Tracked working-tree changes, without committing them: stash create writes a dangling
        # commit and leaves the working tree alone. Untracked files stay out, as with any ref.
        archive_ref="$(git -C "${src}" stash create)"
        [[ -n "${archive_ref}" ]] || archive_ref="$(git -C "${src}" rev-parse HEAD)"
        sha="worktree-$(git -C "${src}" rev-parse --short HEAD)"
    else
        sha="$(git -C "${src}" rev-parse --short "${ref}" 2>/dev/null)" || die "unknown defradb ref: ${ref}"
    fi
    for pair in shinzo-indexer-client:shinzo-indexer shinzo-host-client:shinzo-host; do
        repo="${pair%%:*}"; image="${pair#*:}:${tag}"
        ctx="$(mktemp -d)"; dfile="$(mktemp)"
        log "Preparing ${image}: ${repo} working tree + defradb ${ref} (${sha})"
        tar -C "${SNAP_DIR}/${repo}" --exclude .git --exclude .defra --exclude bin -cf - . | tar -x -C "${ctx}"
        mkdir -p "${ctx}/_defradb"
        # archive, not a copy: untracked files in the defradb checkout stay out
        git -C "${src}" archive "${archive_ref}" | tar -x -C "${ctx}/_defradb"
        docker run --rm -v "${ctx}:/w" -w /w -v e2e-gomod-cache:/go/pkg/mod golang:1.26 \
            sh -c 'go mod edit -replace github.com/sourcenetwork/defradb=./_defradb && go mod tidy' \
            || { rm -rf "${ctx}" "${dfile}"; die "go mod tidy failed: ${repo} against defradb ${ref}"; }
        # Inject the local defradb, and make `apt-get upgrade` non-fatal: it fetches whatever
        # the index lists, so a mirror whose pool lags its index (a fresh security update, say)
        # fails the build for reasons that have nothing to do with the code under test.
        awk '!ins && /^COPY go.mod go.sum/ { print "COPY _defradb ./_defradb"; ins = 1 } { print }' \
            "${SNAP_DIR}/${repo}/Dockerfile" \
            | sed 's/&& apt-get upgrade -y/\&\& { apt-get upgrade -y || echo "apt upgrade skipped: mirror pool out of sync"; }/' \
            > "${dfile}"
        if [[ "${PREP_ONLY:-0}" == 1 ]]; then
            log "  PREP_ONLY: context ${ctx}, Dockerfile ${dfile}"
            continue
        fi
        docker build -t "${image}" --label "e2e.defradb_ref=${sha}" -f "${dfile}" "${ctx}" \
            || { rm -rf "${ctx}" "${dfile}"; die "build of ${image} failed"; }
        rm -rf "${ctx}" "${dfile}"
        log "Built ${image} (defradb ${sha})"
    done
}

build() {
    local variant="$1" pair repo image ctx
    # DEFRADB_REF pins the defradb commit; client code comes from the working trees.
    if [[ -n "${DEFRADB_REF:-}" ]]; then
        case "${variant}" in
            baseline)  build_local_defradb baseline "${DEFRADB_REF}"; return ;;
            candidate) build_local_defradb "${CANDIDATE_TAG}" "${DEFRADB_REF}"; return ;;
            *) die "usage: DEFRADB_REF=<git ref> $0 build baseline|candidate" ;;
        esac
    fi
    for pair in shinzo-indexer-client:shinzo-indexer shinzo-host-client:shinzo-host; do
        repo="${pair%%:*}"
        case "${variant}" in
            baseline)
                # A git archive of the ref, so neither the working tree nor a
                # .git directory ends up in the build context.
                local ref="${BASELINE_REF:-HEAD}"
                image="${pair#*:}:baseline"
                ctx="$(mktemp -d)"
                git -C "${SNAP_DIR}/${repo}" archive "${ref}" | tar -x -C "${ctx}"
                log "Building ${image} from ${repo}@${ref} (defradb $(awk '/sourcenetwork\/defradb /{print $2}' "${ctx}/go.mod"))"
                docker build -t "${image}" "${ctx}" || { rm -rf "${ctx}"; die "build of ${image} failed"; }
                rm -rf "${ctx}"
                ;;
            candidate)
                image="${pair#*:}:${CANDIDATE_TAG}"
                log "Building ${image} from ${repo} working tree (defradb $(awk '/sourcenetwork\/defradb /{print $2}' "${SNAP_DIR}/${repo}/go.mod"))"
                docker build -t "${image}" "${SNAP_DIR}/${repo}" || die "build of ${image} failed"
                ;;
            *) die "usage: $0 build baseline|candidate" ;;
        esac
    done
}

# Promotes the current candidate to baseline, keeping the outgoing baseline as
# :baseline-prev. Run it before building a new candidate, so the next benchmark
# compares the new code against what was just tested.
cycle() {
    local r id ref
    for r in shinzo-indexer shinzo-host; do
        image_exists "${r}:${CANDIDATE_TAG}" \
            || die "${r}:${CANDIDATE_TAG} not found — nothing to promote"
    done
    for r in shinzo-indexer shinzo-host; do
        image_exists "${r}:baseline" && docker tag "${r}:baseline" "${r}:baseline-prev"
        docker tag "${r}:${CANDIDATE_TAG}" "${r}:baseline"
        id="$(docker image inspect "${r}:baseline" --format '{{slice .Id 7 19}}')"
        ref="$(docker image inspect "${r}:baseline" --format '{{index .Config.Labels "e2e.defradb_ref"}}')"
        log "${r}: baseline ← ${CANDIDATE_TAG} (${id}, defradb ${ref:-unlabelled})"
    done
}

main() {
    case "${1:-}" in
        run)
            trap on_exit EXIT
            run_one "${2:-run}" "${GEN_IMAGE:-shinzo-indexer:${CANDIDATE_TAG}}" "${HOST_IMAGE:-shinzo-host:${CANDIDATE_TAG}}"
            [[ "${LAST_PASS}" == true ]] || exit 1
            ;;
        ab)
            trap on_exit EXIT
            run_one baseline "${BASELINE_GEN_IMAGE:-shinzo-indexer:baseline}" "${BASELINE_HOST_IMAGE:-shinzo-host:baseline}"
            run_one candidate "shinzo-indexer:${CANDIDATE_TAG}" "shinzo-host:${CANDIDATE_TAG}"
            compare "${RESULTS_DIR}/baseline.json" "${RESULTS_DIR}/candidate.json"
            ;;
        compare)    compare "${2:-}" "${3:-}" ;;
        compare-md) compare_md "${2:-}" "${3:-}" ;;
        compare-json) compare_rows "${2:-}" "${3:-}" ;;
        car-md)     car_md "${2:-}" ;;
        build)      build "${2:-}" ;;
        cycle)      cycle ;;
        down)       teardown ;;
        *) sed -n '4,44p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
    esac
}

main "$@"
