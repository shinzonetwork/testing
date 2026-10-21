#!/usr/bin/env bash
set -euo pipefail

# Demand-side benchmark: how many GraphQL reads per second a host serves while it is
# creating attestations, and what that read load costs ingest.
#
# One generator indexes a historical range from a real Ethereum RPC into one host. Once the
# host holds PRELOAD blocks, the run goes through these phases:
#
#   ingest           BASELINE_SECONDS, no reads: the attestation rate on its own
#   ingest+read      one step per VUS level, STEP_SECONDS each: reads while attesting
#   ingest-after     BASELINE_SECONDS, no reads again, to check for drift over the run
#   read-only        the generator is stopped, the host goes idle, then the same VUS steps:
#                    read capacity with nothing being attested
#
# Reads come from k6 (readload.js) in a container on the same Docker network, as a closed
# loop: each of VUS clients sends its next query when the last one returns, so throughput
# levels off once the host is saturated. The query mix is point reads by block number on
# indexed fields, latest blocks, a relation join, attestation records, and a small share
# of tx-by-hash (unindexed).
#
# Per phase step:
#   reads_per_s, p50/p95/p99 ms, error and empty-result rates, p50/p95 per query type
#   attest_per_s     host "Created attestation for block N" lines in the window
#   commit_per_s     generator "Committed block N" lines in the window
#   prop_p50/p95_ms  attestation time minus commit time, for blocks attested in the window
#   visible_p50/p95  first time the block showed up in a host query minus its commit time
#                    (polled every 250ms from this machine, so ±250ms plus clock skew)
#   cpu_avg_pct, mem_max_mib   host container, from docker stats
#
# Usage:
#   GETH_RPC_URL=https://... GETH_API_KEY=... ./readload.sh
#
# Env:
#   GETH_RPC_URL, GETH_WS_URL, GETH_API_KEY, GETH_API_KEY_TYPE   as for blocktime.sh
#   GEN_IMAGE         default ghcr.io/shinzonetwork/shinzo-generator-client:v0.7.0-ethereum-mainnet
#   HOST_IMAGE        default ghcr.io/shinzonetwork/shinzo-host-client:v0.7.0-ethereum-mainnet
#   K6_IMAGE          default grafana/k6:0.54.0
#   VUS               concurrency levels, default "1 4 16 64"
#   STEP_SECONDS      per VUS level, default 30
#   BASELINE_SECONDS  each no-read window, default 60
#   PRELOAD           blocks the host must attest before measuring, default 50
#   BLOCKS            blocks the generator indexes in total, default 5000 (enough to keep it busy)
#   START_HEIGHT      first block (default: chain head - BLOCKS - 100)
#   BLOCKS_PER_MINUTE generator rate limit, default 100000 (effectively off)
#   HOST_CPUS         docker --cpus for the host (default: unlimited)
#   KEEP=1            leave the containers running
#   OUT_DIR           where results go (default results/readload-<timestamp>)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in "${SCRIPT_DIR}/../.env" "${SCRIPT_DIR}/.env"; do
    [[ -f "${f}" ]] && { set -a; source "${f}"; set +a; }
done
: "${GETH_RPC_URL:?set GETH_RPC_URL (env var, or in e2e/.env — see .env.sample)}"
GETH_WS_URL="${GETH_WS_URL:-$(sed -E 's#^http#ws#' <<< "${GETH_RPC_URL}")}"
GETH_API_KEY="${GETH_API_KEY:-}"
GETH_API_KEY_TYPE="${GETH_API_KEY_TYPE:-$([[ -n "${GETH_API_KEY}" ]] && echo x-goog-api-key || echo)}"
GEN_IMAGE="${GEN_IMAGE:-ghcr.io/shinzonetwork/shinzo-generator-client:v0.7.0-ethereum-mainnet}"
HOST_IMAGE="${HOST_IMAGE:-ghcr.io/shinzonetwork/shinzo-host-client:v0.7.0-ethereum-mainnet}"
K6_IMAGE="${K6_IMAGE:-grafana/k6:0.54.0}"
VUS="${VUS:-1 4 16 64}"
STEP_SECONDS="${STEP_SECONDS:-30}"
BASELINE_SECONDS="${BASELINE_SECONDS:-60}"
PRELOAD="${PRELOAD:-50}"
BLOCKS="${BLOCKS:-5000}"
BLOCKS_PER_MINUTE="${BLOCKS_PER_MINUTE:-100000}"
PEER_TIMEOUT=120
PRELOAD_TIMEOUT=900
NET=shinzo-readload
SUBNET_PREFIX=172.32.0
HOST_IP="${SUBNET_PREFIX}.21"
GEN_IP="${SUBNET_PREFIX}.11"
HOST_PORT=18201
GEN_PORT=18301
DEFRA_PORT=19181
LABEL="readload-$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-${SCRIPT_DIR}/results/${LABEL}}"
BG_PIDS=()

log() { printf '\033[0;32m[readload]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[0;31m[readload FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
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
gql() {
    curl -s --max-time 10 -H 'Content-Type: application/json' \
        -d "$(jq -cn --arg q "$1" '{query: $q}')" "http://localhost:${DEFRA_PORT}/api/v0/graphql" 2>/dev/null || echo '{}'
}
latest_block() {
    gql '{ Ethereum__Mainnet__Block(order: {number: DESC}, limit: 1) { number } }' \
        | jq -r '.data.Ethereum__Mainnet__Block[0].number // empty' 2>/dev/null || true
}
attest_count() { docker logs rl-host-1 2>&1 | grep -c "Created attestation for block" || true; }
teardown() {
    for p in "${BG_PIDS[@]-}"; do [[ -n "${p}" ]] && kill "${p}" 2>/dev/null || true; done
    docker ps -aq --filter "name=^rl-" | xargs -r docker rm -f >/dev/null 2>&1 || true
    docker network rm "${NET}" >/dev/null 2>&1 || true
}
cleanup() {
    for p in "${BG_PIDS[@]-}"; do [[ -n "${p}" ]] && kill "${p}" 2>/dev/null || true; done
    [[ "${KEEP:-0}" == 1 ]] || teardown
}
trap cleanup EXIT

if [[ -z "${START_HEIGHT:-}" ]]; then
    key_hdr=(); [[ -n "${GETH_API_KEY}" ]] && key_hdr=(-H "${GETH_API_KEY_TYPE}: ${GETH_API_KEY}")
    resp="$(curl -sS --max-time 15 -H 'Content-Type: application/json' "${key_hdr[@]}" \
        -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' "${GETH_RPC_URL}" 2>&1 || true)"
    head_hex="$(jq -r '.result // empty' <<< "${resp}" 2>/dev/null || true)"
    [[ -n "${head_hex}" ]] || die "could not read chain head from GETH_RPC_URL: ${resp:0:300}"
    START_HEIGHT=$(( head_hex - BLOCKS - 100 ))
fi
FROM="${START_HEIGHT}"
PRELOAD_END=$(( FROM + PRELOAD - 1 ))
mkdir -p "${OUT_DIR}"
cp "${SCRIPT_DIR}/readload.js" "${OUT_DIR}/readload.js"
sed -e "s#^  start_height: .*#  start_height: ${FROM}#" "${SCRIPT_DIR}/host.yaml" > "${OUT_DIR}/host.yaml"

docker image inspect "${GEN_IMAGE}" >/dev/null 2>&1 || docker pull -q "${GEN_IMAGE}" >/dev/null
docker image inspect "${HOST_IMAGE}" >/dev/null 2>&1 || docker pull -q "${HOST_IMAGE}" >/dev/null
docker image inspect "${K6_IMAGE}" >/dev/null 2>&1 || docker pull -q "${K6_IMAGE}" >/dev/null
log "gen ${GEN_IMAGE}"
log "host ${HOST_IMAGE}"
log "blocks from ${FROM}, preload ${PRELOAD}, VUS ${VUS} × ${STEP_SECONDS}s, baselines ${BASELINE_SECONDS}s"

teardown
docker network create --subnet "${SUBNET_PREFIX}.0/24" "${NET}" >/dev/null

cpu_flag=(); [[ -n "${HOST_CPUS:-}" ]] && cpu_flag=(--cpus "${HOST_CPUS}")
docker run -d --name rl-host-1 --network "${NET}" --ip "${HOST_IP}" \
    -p "${HOST_PORT}:8080" -p "${DEFRA_PORT}:9181" ${cpu_flag[@]+"${cpu_flag[@]}"} \
    --memory 3g -e GOMEMLIMIT=2GiB -e DEFRA_URL=0.0.0.0:9181 -e LOG_LEVEL=info \
    -e LOG_SOURCE=false -e LOG_STACKTRACE=false -e BOOTSTRAP_PEERS= \
    -v "${OUT_DIR}/host.yaml:/app/config.yaml:ro" "${HOST_IMAGE}" >/dev/null
host_id="$(wait_peer_id rl-host-1 "${HOST_PORT}")"
log "rl-host-1 up: ${host_id}"

sed -e "s|__LISTEN_IP__|${GEN_IP}|" -e "s|__BOOTSTRAP_PEERS__|[\"/ip4/${HOST_IP}/tcp/9171/p2p/${host_id}\"]|" \
    -e "s#blocks_per_minute: .*#blocks_per_minute: ${BLOCKS_PER_MINUTE}#" \
    "${SCRIPT_DIR}/generator.template.yaml" > "${OUT_DIR}/gen.yaml"
docker run -d --name rl-gen-1 --network "${NET}" --ip "${GEN_IP}" -p "${GEN_PORT}:8080" \
    --memory 3g -e GOMEMLIMIT=2GiB \
    -v "${OUT_DIR}/gen.yaml:/app/config/config.yaml:ro" \
    -e GETH_RPC_URL="${GETH_RPC_URL}" -e GETH_WS_URL="${GETH_WS_URL}" \
    -e GETH_API_KEY="${GETH_API_KEY}" -e GETH_API_KEY_TYPE="${GETH_API_KEY_TYPE}" \
    -e DEFRADB_KEYRING_SECRET=readload-secret -e DEFRADB_P2P_ACCEPT_INCOMING=false \
    -e INDEXER_START_HEIGHT="${FROM}" -e SNAPSHOT_ENABLED=false -e LOG_LEVEL=info \
    -e LOG_SOURCE=false -e LOG_STACKTRACE=false -e SCHEMA_AUTH_MODE=none \
    "${GEN_IMAGE}" >/dev/null
log "rl-gen-1 up: $(wait_peer_id rl-gen-1 "${GEN_PORT}")"

# Background samplers: host CPU/memory, and the newest block visible to a query.
( while :; do
    s="$(docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' rl-host-1 2>/dev/null || true)"
    [[ -n "${s}" ]] && echo "$(now_ms) ${s}"
  done ) > "${OUT_DIR}/stats.txt" &
BG_PIDS+=($!)
python3 -I - "http://localhost:${DEFRA_PORT}/api/v0/graphql" > "${OUT_DIR}/visible.txt" <<'PY' &
import json, sys, time, urllib.request
url = sys.argv[1]
body = json.dumps({"query": "{ Ethereum__Mainnet__Block(order: {number: DESC}, limit: 1) { number } }"}).encode()
while True:
    t = time.time()
    try:
        req = urllib.request.Request(url, body, {"Content-Type": "application/json"})
        rows = json.load(urllib.request.urlopen(req, timeout=5))["data"]["Ethereum__Mainnet__Block"]
        if rows:
            print(int(t * 1000), rows[0]["number"], flush=True)
    except Exception:
        pass
    time.sleep(max(0, 0.25 - (time.time() - t)))
PY
BG_PIDS+=($!)

log "waiting for the host to attest block ${PRELOAD_END}"
start="${SECONDS}"
until docker logs rl-host-1 2>&1 | grep -q "Created attestation for block ${PRELOAD_END} "; do
    (( SECONDS - start > PRELOAD_TIMEOUT )) && { docker logs --tail 40 rl-gen-1 >&2; die "host did not attest block ${PRELOAD_END} within ${PRELOAD_TIMEOUT}s"; }
    [[ "$(docker inspect -f '{{.State.Running}}' rl-gen-1 2>/dev/null)" == true ]] || die "rl-gen-1 exited"
    sleep 2
done
log "preload done after $(( SECONDS - start ))s"

hashes="$(gql '{ Ethereum__Mainnet__Transaction(limit: 200) { hash } }' \
    | jq -c '[.data.Ethereum__Mainnet__Transaction[]?.hash | select(. != null)]' 2>/dev/null || echo '[]')"
echo "${hashes}" > "${OUT_DIR}/hashes.json"
log "sampled $(jq length <<< "${hashes}") tx hashes"

phases="[]"
add_phase() {  # phase vus start_ms end_ms [k6 summary file]
    phases="$(jq -c --arg p "$1" --argjson v "$2" --argjson s "$3" --argjson e "$4" --arg f "${5:-}" \
        '. + [{phase: $p, vus: $v, start_ms: $s, end_ms: $e, k6: $f}]' <<< "${phases}")"
}
idle_window() {  # phase
    local s; s="$(now_ms)"
    log "  $1: ${BASELINE_SECONDS}s, no reads"
    sleep "${BASELINE_SECONDS}"
    add_phase "$1" 0 "${s}" "$(now_ms)"
}
read_sweep() {  # phase
    local v max s f
    for v in ${VUS}; do
        max="$(latest_block)"; [[ -n "${max}" ]] || max="${PRELOAD_END}"
        f="k6-$1-${v}.json"
        log "  $1: ${v} VUs × ${STEP_SECONDS}s over blocks ${FROM}..${max}"
        s="$(now_ms)"
        docker run --rm --network "${NET}" -v "${OUT_DIR}:/work" \
            -e GQL_URL="http://${HOST_IP}:9181/api/v0/graphql" -e VUS="${v}" -e DURATION="${STEP_SECONDS}" \
            -e MIN_BLOCK="${FROM}" -e MAX_BLOCK="${max}" -e HASHES=/work/hashes.json \
            "${K6_IMAGE}" run --quiet --no-color --summary-export "/work/${f}" \
            --summary-trend-stats 'avg,med,p(95),p(99),max' /work/readload.js \
            > "${OUT_DIR}/k6-$1-${v}.log" 2>&1 || log "  k6 exited non-zero (see k6-$1-${v}.log)"
        add_phase "$1" "${v}" "${s}" "$(now_ms)" "${f}"
    done
}

idle_window ingest
read_sweep ingest+read
idle_window ingest-after

log "stopping the generator; waiting for the host to go idle"
docker logs rl-gen-1 > "${OUT_DIR}/gen.log" 2>&1 || true
docker stop rl-gen-1 >/dev/null
prev=-1; start="${SECONDS}"
while :; do
    n="$(attest_count)"
    [[ "${n}" == "${prev}" ]] && break
    (( SECONDS - start > 300 )) && { log "  host still attesting after 300s; measuring anyway"; break; }
    prev="${n}"; sleep 15
done
read_sweep read-only

docker logs rl-host-1 > "${OUT_DIR}/host.log" 2>&1 || true
echo "${phases}" > "${OUT_DIR}/phases.json"

python3 -I - "${OUT_DIR}" <<'PY' > "${OUT_DIR}/result.json"
import json, os, re, sys
from datetime import datetime, timezone
d = sys.argv[1]

def times(path, pat):
    out = {}
    for line in open(path, errors="replace"):
        g = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?Z\s.*" + pat + r" (\d+)\b", line)
        if g:
            frac = (g.group(2) or ".0")[:7]
            t = datetime.fromisoformat(g.group(1) + frac).replace(tzinfo=timezone.utc).timestamp() * 1000
            b = int(g.group(3))
            out[b] = min(out.get(b, t), t)
    return out

def pct(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    return round(xs[min(len(xs) - 1, int(p / 100 * len(xs)))], 1)

commit = times(f"{d}/gen.log", "Committed block")
attest = times(f"{d}/host.log", "Created attestation for block")
# A block is visible from the first poll whose newest block is at or past it.
visible, last = {}, None
for line in open(f"{d}/visible.txt"):
    t, n = map(int, line.split())
    for b in range(n if last is None else last + 1, n + 1):
        visible[b] = t
    last = n if last is None else max(last, n)
stats = []
for line in open(f"{d}/stats.txt"):
    parts = line.split()
    if len(parts) < 3:
        continue
    mem = re.match(r"([\d.]+)([KMG]i?B)", parts[2])
    mib = float(mem.group(1)) * {"KiB": 1 / 1024, "MiB": 1, "GiB": 1024, "KB": 1 / 1024, "MB": 1, "GB": 1024}.get(mem.group(2), 1) if mem else None
    stats.append((int(parts[0]), float(parts[1].rstrip("%")), mib))

def k6(f):
    if not f or not os.path.exists(f"{d}/{f}"):
        return None
    m = json.load(open(f"{d}/{f}"))["metrics"]
    dur = m.get("http_req_duration", {})
    r = {
        "reads": m.get("http_reqs", {}).get("count"),
        "reads_per_s": round(m.get("http_reqs", {}).get("rate", 0), 1),
        "p50_ms": round(dur.get("med", 0), 1), "p95_ms": round(dur.get("p(95)", 0), 1),
        "p99_ms": round(dur.get("p(99)", 0), 1), "max_ms": round(dur.get("max", 0), 1),
        "error_rate": round(m.get("gql_errors", {}).get("value", 0), 4),
        "empty_rate": round(m.get("empty_results", {}).get("value", 0), 4),
        "by_query": {},
    }
    for k, v in m.items():
        if k.startswith("lat_"):
            r["by_query"][k[4:]] = {"p50_ms": round(v.get("med", 0), 1), "p95_ms": round(v.get("p(95)", 0), 1),
                                    "p99_ms": round(v.get("p(99)", 0), 1)}
    return r

out = []
for ph in json.load(open(f"{d}/phases.json")):
    s, e = ph["start_ms"], ph["end_ms"]
    secs = (e - s) / 1000
    inwin = lambda t: s <= t < e
    att = [b for b, t in attest.items() if inwin(t)]
    prop = [attest[b] - commit[b] for b in att if b in commit]
    vis = [visible[b] - commit[b] for b, t in visible.items() if inwin(t) and b in commit]
    st = [x for x in stats if inwin(x[0])]
    out.append({
        "phase": ph["phase"], "vus": ph["vus"], "seconds": round(secs, 1),
        "attest_per_s": round(len(att) / secs, 2),
        "commit_per_s": round(sum(1 for t in commit.values() if inwin(t)) / secs, 2),
        "prop_p50_ms": pct(prop, 50), "prop_p95_ms": pct(prop, 95),
        "visible_p50_ms": pct(vis, 50), "visible_p95_ms": pct(vis, 95),
        "cpu_avg_pct": round(sum(x[1] for x in st) / len(st), 1) if st else None,
        "mem_max_mib": round(max(x[2] for x in st if x[2] is not None), 0) if st else None,
        "read": k6(ph["k6"]),
    })
json.dump({"phases": out}, sys.stdout, indent=1)
PY

jq --arg gen "${GEN_IMAGE}" --arg host "${HOST_IMAGE}" --argjson from "${FROM}" \
    '{gen_image: $gen, host_image: $host, start_height: $from} + .' "${OUT_DIR}/result.json" > "${OUT_DIR}/result.tmp" \
    && mv "${OUT_DIR}/result.tmp" "${OUT_DIR}/result.json"

{
    echo "# Read-load benchmark ${LABEL}"
    echo
    echo "- gen: ${GEN_IMAGE}"
    echo "- host: ${HOST_IMAGE}"
    echo "- blocks from ${FROM}, VUS ${VUS} × ${STEP_SECONDS}s, baselines ${BASELINE_SECONDS}s${HOST_CPUS:+, host --cpus ${HOST_CPUS}}"
    echo
    echo "| phase | VUs | reads/s | p50 ms | p95 ms | p99 ms | err | attest/s | commit/s | prop p50/p95 ms | visible p50/p95 ms | host CPU % | host mem MiB |"
    echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|"
    jq -r '.phases[] | [.phase, .vus, .read.reads_per_s, .read.p50_ms, .read.p95_ms, .read.p99_ms,
        (if .read then (.read.error_rate * 100 | tostring) + "%" else null end),
        .attest_per_s, .commit_per_s, "\(.prop_p50_ms // "-") / \(.prop_p95_ms // "-")",
        "\(.visible_p50_ms // "-") / \(.visible_p95_ms // "-")", .cpu_avg_pct, .mem_max_mib]
        | map(. // "-" | tostring) | "| " + join(" | ") + " |"' "${OUT_DIR}/result.json"
    echo
    echo "## p95 ms by query type"
    echo
    types="$(jq -r '[.phases[] | .read.by_query // {} | keys[]] | unique | join(" ")' "${OUT_DIR}/result.json")"
    echo "| phase | VUs | ${types// / | } |"
    echo "|---|---|$(for _ in ${types}; do printf -- '---|'; done)"
    jq -r --arg t "${types}" '.phases[] | select(.read) | . as $p |
        [$p.phase, $p.vus] + ($t | split(" ") | map($p.read.by_query[.].p95_ms))
        | map(. // "-" | tostring) | "| " + join(" | ") + " |"' "${OUT_DIR}/result.json"
} > "${OUT_DIR}/results.md"
echo
cat "${OUT_DIR}/results.md"
echo
log "results: ${OUT_DIR}/results.md, ${OUT_DIR}/result.json"
