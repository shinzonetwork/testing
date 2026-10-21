#!/usr/bin/env bash
set -euo pipefail

# Block-time benchmark against a real Ethereum RPC: how long a generator takes
# to index blocks, and how long until each host has created the attestation.
#
# For each mesh size M in MESHES, starts M hosts and M generators in a full P2P
# mesh (hosts first, so they are listening before any block is published), and
# has every generator index the same historical range. WARMUP blocks run first,
# so the measured window starts once gossip is flowing.
#
# Timing comes from the nodes' own log timestamps (same Docker VM clock):
#   gen   "Committed block N"               — earliest across generators
#   host  "Created attestation for block N" — first per host
# The window starts when the last warmup block is committed (the generator then
# begins block START_HEIGHT). For each K in COUNTS:
#   gen_ms      until block START_HEIGHT+K-1 is committed
#   host_ms     until the slowest host has attested block START_HEIGHT+K-1
#   prop_*_ms   per block, attestation time minus commit time (slowest host)
#
# Usage:
#   GETH_RPC_URL=https://... GETH_API_KEY=... ./blocktime.sh
#
# Env:
#   GETH_RPC_URL         HTTP JSON-RPC endpoint (required)
#   GETH_WS_URL          WebSocket endpoint (default: GETH_RPC_URL with ws(s)://)
#   GETH_API_KEY         API key (default: none)
#   GETH_API_KEY_TYPE    header name the key is sent in (default x-goog-api-key when a key is set)
#   GEN_IMAGE            default ghcr.io/shinzonetwork/shinzo-generator-client:v0.7.0-ethereum-mainnet
#   HOST_IMAGE           default ghcr.io/shinzonetwork/shinzo-host-client:v0.7.0-ethereum-mainnet
#   MESHES               mesh sizes (generators = hosts = M), default "1 2 3"
#   COUNTS               block windows, default "1 10 100"
#   WARMUP               blocks indexed before the window, default 10
#   START_HEIGHT         first measured block (default: chain head - 1000)
#   BLOCKS_PER_MINUTE    generator rate limit (default 100000, i.e. effectively off;
#                        the shipped config uses 120 = one block per 500ms)
#   CONCURRENT_BLOCKS    default 1 (shipped config)
#   TIMEOUT_SECONDS      per mesh, default 1800
#   KEEP=1               leave the last mesh running
#   OUT_DIR              where results go (default results/blocktime-<timestamp>)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in "${SCRIPT_DIR}/../.env" "${SCRIPT_DIR}/.env"; do
    [[ -f "${f}" ]] && { set -a; source "${f}"; set +a; }
done
: "${GETH_RPC_URL:?set GETH_RPC_URL (env var, or in e2e/.env — see .env.sample)}"
GETH_WS_URL="${GETH_WS_URL:-$(sed -E 's#^http#ws#' <<< "${GETH_RPC_URL}")}"
GETH_API_KEY="${GETH_API_KEY:-}"
# The generator sends the key in a header named GETH_API_KEY_TYPE (Google Blockchain Node Engine: x-goog-api-key).
GETH_API_KEY_TYPE="${GETH_API_KEY_TYPE:-$([[ -n "${GETH_API_KEY}" ]] && echo x-goog-api-key || echo)}"
GEN_IMAGE="${GEN_IMAGE:-ghcr.io/shinzonetwork/shinzo-generator-client:v0.7.0-ethereum-mainnet}"
HOST_IMAGE="${HOST_IMAGE:-ghcr.io/shinzonetwork/shinzo-host-client:v0.7.0-ethereum-mainnet}"
MESHES="${MESHES:-1 2 3}"
COUNTS="${COUNTS:-1 10 100}"
WARMUP="${WARMUP:-10}"
BLOCKS_PER_MINUTE="${BLOCKS_PER_MINUTE:-100000}"
CONCURRENT_BLOCKS="${CONCURRENT_BLOCKS:-1}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1800}"
PEER_TIMEOUT=120
NET=shinzo-blocktime
SUBNET_PREFIX=172.31.0
LABEL="blocktime-$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-${SCRIPT_DIR}/results/${LABEL}}"

log() { printf '\033[0;32m[blocktime]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[0;31m[blocktime FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
health() { curl -s --max-time 2 "http://localhost:$1/health" 2>/dev/null || echo '{}'; }
peer_id() {
    health "$1" | jq -r '
        .p2p.self.id // .p2p.self.peer_id // .p2p.self.peerID //
        .p2p.peer_id // .peer_id // .peerID // .peerInfo.id // empty' 2>/dev/null || true
}
wait_peer_id() {
    local name="$1" port="$2" id="" start="${SECONDS}"
    while [[ -z "${id}" ]]; do
        (( SECONDS - start > PEER_TIMEOUT )) && { docker logs --tail 80 "${name}" >&2; die "${name}: no peer ID after ${PEER_TIMEOUT}s"; }
        sleep 1
        id="$(peer_id "${port}")"
    done
    echo "${id}"
}
teardown() {
    docker ps -aq --filter "name=^bt-" | xargs -r docker rm -f >/dev/null 2>&1 || true
    docker network rm "${NET}" >/dev/null 2>&1 || true
}
trap '[[ "${KEEP:-0}" == 1 ]] || teardown' EXIT

if [[ -z "${START_HEIGHT:-}" ]]; then
    key_hdr=(); [[ -n "${GETH_API_KEY}" ]] && key_hdr=(-H "${GETH_API_KEY_TYPE}: ${GETH_API_KEY}")
    resp="$(curl -sS --max-time 15 -H 'Content-Type: application/json' "${key_hdr[@]}" \
        -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' "${GETH_RPC_URL}" 2>&1 || true)"
    head_hex="$(jq -r '.result // empty' <<< "${resp}" 2>/dev/null || true)"
    [[ -n "${head_hex}" ]] || die "could not read chain head from GETH_RPC_URL: ${resp:0:300}"
    START_HEIGHT=$(( head_hex - 1000 ))
fi
MAX_COUNT=$(tr ' ' '\n' <<< "${COUNTS}" | sort -n | tail -1)
FROM=$(( START_HEIGHT - WARMUP ))
END=$(( START_HEIGHT + MAX_COUNT - 1 ))
mkdir -p "${OUT_DIR}"

# Host config: start where the generators start, so it does not wait on a gap from 0.
sed -e "s#^  start_height: .*#  start_height: ${FROM}#" "${SCRIPT_DIR}/host.yaml" > "${OUT_DIR}/host.yaml"

docker image inspect "${GEN_IMAGE}" >/dev/null 2>&1 || docker pull -q "${GEN_IMAGE}" >/dev/null
docker image inspect "${HOST_IMAGE}" >/dev/null 2>&1 || docker pull -q "${HOST_IMAGE}" >/dev/null
log "gen ${GEN_IMAGE}"
log "host ${HOST_IMAGE}"
log "blocks ${FROM}..${END} (warmup ${WARMUP}, measured from ${START_HEIGHT}), blocks/min limit ${BLOCKS_PER_MINUTE}, concurrent ${CONCURRENT_BLOCKS}"

run_mesh() {
    local m="$1" dir="${OUT_DIR}/mesh-$1" addrs=() i name ip port id peers
    mkdir -p "${dir}"
    teardown
    docker network create --subnet "${SUBNET_PREFIX}.0/24" "${NET}" >/dev/null

    # Hosts first; each bootstraps to the hosts before it.
    for (( i = 1; i <= m; i++ )); do
        name="bt-host-${i}"; ip="${SUBNET_PREFIX}.$(( 20 + i ))"; port=$(( 18100 + i ))
        docker run -d --name "${name}" --network "${NET}" --ip "${ip}" -p "${port}:8080" \
            --memory 3g -e GOMEMLIMIT=2GiB -e DEFRA_URL=0.0.0.0:9181 -e LOG_LEVEL=info \
            -e LOG_SOURCE=false -e LOG_STACKTRACE=false \
            -e BOOTSTRAP_PEERS="$(IFS=,; echo "${addrs[*]-}")" \
            -v "${OUT_DIR}/host.yaml:/app/config.yaml:ro" "${HOST_IMAGE}" >/dev/null
        id="$(wait_peer_id "${name}" "${port}")"
        log "  ${name} up: ${id}"
        addrs+=("/ip4/${ip}/tcp/9171/p2p/${id}")
    done

    # Generators bootstrap to every host and every generator before them, then start indexing.
    for (( i = 1; i <= m; i++ )); do
        name="bt-gen-${i}"; ip="${SUBNET_PREFIX}.$(( 10 + i ))"; port=$(( 18000 + i ))
        peers="[$(printf '"%s",' "${addrs[@]}" | sed 's/,$//')]"
        sed -e "s|__LISTEN_IP__|${ip}|" -e "s|__BOOTSTRAP_PEERS__|${peers}|" \
            -e "s#blocks_per_minute: .*#blocks_per_minute: ${BLOCKS_PER_MINUTE}#" \
            -e "s#concurrent_blocks: .*#concurrent_blocks: ${CONCURRENT_BLOCKS}#" \
            "${SCRIPT_DIR}/generator.template.yaml" > "${dir}/${name}.yaml"
        docker run -d --name "${name}" --network "${NET}" --ip "${ip}" -p "${port}:8080" \
            --memory 3g -e GOMEMLIMIT=2GiB \
            -v "${dir}/${name}.yaml:/app/config/config.yaml:ro" \
            -e GETH_RPC_URL="${GETH_RPC_URL}" -e GETH_WS_URL="${GETH_WS_URL}" \
            -e GETH_API_KEY="${GETH_API_KEY}" -e GETH_API_KEY_TYPE="${GETH_API_KEY_TYPE}" \
            -e DEFRADB_KEYRING_SECRET=blocktime-secret -e DEFRADB_P2P_ACCEPT_INCOMING=false \
            -e INDEXER_START_HEIGHT="${FROM}" -e SNAPSHOT_ENABLED=false -e LOG_LEVEL=info \
            -e LOG_SOURCE=false -e LOG_STACKTRACE=false -e SCHEMA_AUTH_MODE=none \
            "${GEN_IMAGE}" >/dev/null
        id="$(wait_peer_id "${name}" "${port}")"
        log "  ${name} up: ${id}"
        addrs+=("/ip4/${ip}/tcp/9171/p2p/${id}")
    done

    # Wait until every host has attested the last block.
    local start="${SECONDS}" done_hosts
    while :; do
        done_hosts=0
        for (( i = 1; i <= m; i++ )); do
            docker logs "bt-host-${i}" 2>&1 | grep -q "Created attestation for block ${END} " && done_hosts=$(( done_hosts + 1 ))
        done
        (( done_hosts == m )) && break
        (( SECONDS - start > TIMEOUT_SECONDS )) && { log "  timeout: ${done_hosts}/${m} hosts attested block ${END}"; break; }
        for (( i = 1; i <= m; i++ )); do
            [[ "$(docker inspect -f '{{.State.Running}}' "bt-gen-${i}" 2>/dev/null)" == true ]] \
                || { log "  bt-gen-${i} exited"; break 2; }
        done
        sleep 1
    done
    log "  ${done_hosts}/${m} hosts attested block ${END} after $(( SECONDS - start ))s"

    for (( i = 1; i <= m; i++ )); do
        docker logs "bt-gen-${i}" > "${dir}/gen-${i}.log" 2>&1 || true
        docker logs "bt-host-${i}" > "${dir}/host-${i}.log" 2>&1 || true
    done
}

analyze() {
    python3 - "$1" "$2" "${START_HEIGHT}" "${COUNTS}" <<'PY'
import glob, json, re, sys
from datetime import datetime
d, m, start, counts = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), [int(c) for c in sys.argv[4].split()]
def times(path, pat):
    out = {}
    for line in open(path, errors="replace"):
        g = re.match(r"(\d{4}-\d\d-\d\dT[\d:.]+)Z\s.*" + pat + r" (\d+)\b", line)
        if g:
            t = datetime.fromisoformat(g.group(1)).timestamp() * 1000
            b = int(g.group(2))
            out[b] = min(out.get(b, t), t)
    return out
commit = {}
for p in sorted(glob.glob(f"{d}/gen-*.log")):
    for b, t in times(p, "Committed block").items():
        commit[b] = min(commit.get(b, t), t)
hosts = [times(p, "Created attestation for block") for p in sorted(glob.glob(f"{d}/host-*.log"))]
ref = commit.get(start - 1)
runs = []
for k in counts:
    last, blocks = start + k - 1, range(start, start + k)
    r = {"blocks": k, "ok": ref is not None and last in commit and all(last in h for h in hosts)}
    if r["ok"]:
        r["gen_ms"] = round(commit[last] - ref)
        r["gen_ms_per_block"] = round(r["gen_ms"] / k, 1)
        r["host_ms"] = round(max(h[last] for h in hosts) - ref)
        r["host_ms_per_block"] = round(r["host_ms"] / k, 1)
        prop = [max(h[b] for h in hosts) - commit[b] for b in blocks
                if b in commit and all(b in h for h in hosts)]
        r["prop_avg_ms"] = round(sum(prop) / len(prop), 1) if prop else None
        r["prop_max_ms"] = round(max(prop)) if prop else None
        r["missing_on_hosts"] = sum(1 for b in blocks for h in hosts if b not in h)
    runs.append(r)
print(json.dumps({"mesh": m, "runs": runs}))
PY
}

meshes="[]"
for m in ${MESHES}; do
    log "═══ mesh ${m}×${m}"
    run_mesh "${m}"
    meshes="$(jq -c --argjson r "$(analyze "${OUT_DIR}/mesh-${m}" "${m}")" '. + [$r]' <<< "${meshes}")"
done

jq -n --arg gen "${GEN_IMAGE}" --arg host "${HOST_IMAGE}" --argjson start "${START_HEIGHT}" \
    --argjson warmup "${WARMUP}" --argjson bpm "${BLOCKS_PER_MINUTE}" --argjson conc "${CONCURRENT_BLOCKS}" \
    --argjson meshes "${meshes}" \
    '{gen_image: $gen, host_image: $host, start_height: $start, warmup: $warmup,
      blocks_per_minute: $bpm, concurrent_blocks: $conc, meshes: $meshes}' > "${OUT_DIR}/result.json"

{
    echo "# Block-time benchmark ${LABEL}"
    echo
    echo "- gen: ${GEN_IMAGE}"
    echo "- host: ${HOST_IMAGE}"
    echo "- blocks from ${START_HEIGHT} (warmup ${WARMUP}), blocks/min limit ${BLOCKS_PER_MINUTE}, concurrent ${CONCURRENT_BLOCKS}"
    echo
    echo "| mesh | blocks | ok | gen ms | gen ms/blk | host ms | host ms/blk | prop avg ms | prop max ms |"
    echo "|---|---|---|---|---|---|---|---|---|"
    jq -r '.meshes[] | .mesh as $m | .runs[] |
        ["\($m)x\($m)", .blocks, .ok, .gen_ms, .gen_ms_per_block, .host_ms, .host_ms_per_block, .prop_avg_ms, .prop_max_ms]
        | map(. // "-" | tostring) | "| " + join(" | ") + " |"' "${OUT_DIR}/result.json"
} > "${OUT_DIR}/results.md"
echo
cat "${OUT_DIR}/results.md"
echo
log "results: ${OUT_DIR}/results.md, ${OUT_DIR}/result.json  (logs per mesh in ${OUT_DIR}/mesh-N/)"
