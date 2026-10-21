#!/usr/bin/env bash
set -uo pipefail  # no -e: every stage records its result and the suite carries on

# ───────────────────────────────────────────────────────────────
# Shinzo E2E-multi release suite
#
# Runs every check in this harness, baseline vs candidate, and ends
# with what improved, what got worse, and a release verdict.
#
#   1 unit        go vet + go test: defradb p2p package, indexer, host
#   2 build       shinzo-*:baseline (client HEADs) and :candidate (working trees)
#   3 smoke       candidate 3×3 mesh, short window; skips the e2e stages on failure
#   4 benchmark   baseline vs candidate: traffic, CPU, memory, disk, lag
#   5 regression  restart (and freeze, full profile) under load, baseline vs candidate
#   6 compat      mixed-version meshes: every rolling-upgrade order
#   7 realchain   candidate against a real Ethereum RPC: blocktime.sh, readload.sh
#                 (skipped unless GETH_RPC_URL is set)
#   8 report      REPORT.md + summary.json in the suite directory
#
# Usage:
#   ./suite.sh                  PROFILE=quick  (~45 min)
#   PROFILE=full ./suite.sh     adds 1×1 / 1×3 topologies, freeze, high load and
#                               defradb's net integration tests (~110 min)
#
# Env: SKIP_UNIT=1  SKIP_BUILD=1  BASELINE_REF=HEAD  CANDIDATE_TAG=candidate
#      BENCH_SECONDS=180  REG_SECONDS=120  NOISE_PCT=5
#      REPORT_ONLY=1 SUITE_DIR=<dir>   rebuild the report of an earlier suite
#      STAGES=build,smoke,benchmark     run only these stages (default: all)
#      BASELINE_GEN_IMAGE / BASELINE_HOST_IMAGE   compare against these images
#                                       instead of building :baseline
#      REQUIRE_IMPROVEMENT=0            don't require bench-3x3 mesh bytes/block to be
#                                       better (nightly: gate on failures and regressions only)
#      GETH_RPC_URL, GETH_API_KEY, ...  for the realchain stage, as for blocktime.sh
# Exit status: 0 when the verdict is READY, 1 otherwise.
# ───────────────────────────────────────────────────────────────

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAP_DIR="$(cd "${DIR}/../.." && pwd)"
PROFILE="${PROFILE:-quick}"
SKIP_UNIT="${SKIP_UNIT:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
export CANDIDATE_TAG="${CANDIDATE_TAG:-candidate}"
export NOISE_PCT="${NOISE_PCT:-5}"
BENCH_SECONDS="${BENCH_SECONDS:-180}"
REG_SECONDS="${REG_SECONDS:-120}"
SUITE_DIR="${SUITE_DIR:-${DIR}/results/suite-$(date +%Y%m%d-%H%M%S)}"
RUNS="${SUITE_DIR}/runs"
STATUS="${SUITE_DIR}/status.tsv"

# A baseline image given here (e.g. a published release) is used as-is and not built.
BASE_GEN="${BASELINE_GEN_IMAGE:-shinzo-indexer:baseline}"
BASE_HOST="${BASELINE_HOST_IMAGE:-shinzo-host:baseline}"
STAGES="${STAGES:-unit,build,smoke,benchmark,regression,compat,realchain}"
REQUIRE_IMPROVEMENT="${REQUIRE_IMPROVEMENT:-1}"
want() { [[ ",${STAGES}," == *",$1,"* ]]; }
CAND_GEN="shinzo-indexer:${CANDIDATE_TAG}"
CAND_HOST="shinzo-host:${CANDIDATE_TAG}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[suite]${NC} $*"; }
warn() { echo -e "${YELLOW}[suite]${NC} $*"; }

mkdir -p "${RUNS}" "${SUITE_DIR}/logs"

# record STAGE NAME PASS|FAIL|WARN|SKIP DETAIL
record() {
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "${STATUS}"
    local colour="${GREEN}"
    case "$3" in FAIL) colour="${RED}" ;; WARN|SKIP) colour="${YELLOW}" ;; esac
    echo -e "        ${colour}$3${NC} $1/$2 — $4"
}

stage_failed() { awk -F'\t' -v s="$1" '$1 == s && $3 == "FAIL" {f = 1} END {exit !f}' "${STATUS}"; }

# ── 0 preflight ──────────────────────────────────────────────
preflight() {
    local tool missing=""
    for tool in docker jq curl git awk column; do command -v "${tool}" >/dev/null || missing+=" ${tool}"; done
    [[ "${SKIP_UNIT}" == 1 ]] || command -v go >/dev/null || missing+=" go"
    want realchain && ! command -v python3 >/dev/null && missing+=" python3"
    [[ -z "${missing}" ]] || { echo "missing tools:${missing} (see GUIDE.md step 1)"; exit 1; }
    docker info >/dev/null 2>&1 || { echo "docker is not running"; exit 1; }
    local mem_gb
    mem_gb=$(( $(docker info --format '{{.MemTotal}}') / 1073741824 ))
    (( mem_gb >= 12 )) || warn "Docker has ${mem_gb} GiB; 6 nodes want ≥12 GiB (GUIDE.md step 2). Results may show OOM or lag."
    log "profile=${PROFILE}, results → ${SUITE_DIR}"
}

# ── 1 unit ───────────────────────────────────────────────────
# Cases listed here report WARN instead of FAIL. defradb's net integration tests
# panic in corekv/chunk (slice bounds [:1024]) on the pre-CAR commit 0e9634a3 too,
# so they cannot gate this release. Set UNIT_INFORMATIONAL= to make them gate again.
UNIT_INFORMATIONAL="${UNIT_INFORMATIONAL:-defradb-net-integration}"

unit_case() {
    local name="$1" repo="$2" cmd="$3" start="${SECONDS}"
    # bash 3.2 expands every right-hand side before assigning, so a value built
    # from ${name} needs its own statement.
    local logfile="${SUITE_DIR}/logs/unit-${name}.log"
    log "▶ unit/${name}: ${cmd}"
    if ( cd "${SNAP_DIR}/${repo}" && eval "${cmd}" ) > "${logfile}" 2>&1; then
        record unit "${name}" PASS "$(( SECONDS - start ))s"
    else
        if [[ ",${UNIT_INFORMATIONAL}," == *",${name},"* ]]; then
            record unit "${name}" WARN "$(( SECONDS - start ))s, known pre-existing failure, see logs/unit-${name}.log"
            return
        fi
        record unit "${name}" FAIL "$(( SECONDS - start ))s, see logs/unit-${name}.log"
        tail -15 "${logfile}" | sed 's/^/          /'
    fi
}

unit() {
    if [[ "${SKIP_UNIT}" == 1 ]]; then record unit all SKIP "SKIP_UNIT=1"; return; fi
    unit_case defradb-p2p defradb "go vet ./internal/db/p2p/... && go test -count=1 -timeout 15m ./internal/db/p2p/..."
    unit_case indexer shinzo-indexer-client "go vet ./... && go test -count=1 -timeout 20m ./..."
    unit_case host shinzo-host-client "go vet ./... && go test -count=1 -timeout 20m ./..."
    if [[ "${PROFILE}" == full && -d "${SNAP_DIR}/defradb/tests/integration/net" ]]; then
        unit_case defradb-net-integration defradb "go test -count=1 -timeout 45m ./tests/integration/net/..."
    fi
}

# ── 2 build ──────────────────────────────────────────────────
build() {
    local variant
    for variant in baseline candidate; do
        if [[ "${variant}" == baseline && -n "${BASELINE_GEN_IMAGE:-}${BASELINE_HOST_IMAGE:-}" ]]; then
            if docker image inspect "${BASE_GEN}" >/dev/null 2>&1 && docker image inspect "${BASE_HOST}" >/dev/null 2>&1; then
                record build baseline SKIP "using ${BASE_GEN} and ${BASE_HOST}"
            else
                record build baseline FAIL "${BASE_GEN} or ${BASE_HOST} not found locally (docker pull it)"
            fi
            continue
        fi
        if [[ "${SKIP_BUILD}" == 1 ]]; then
            if docker image inspect "shinzo-indexer:${variant/candidate/${CANDIDATE_TAG}}" >/dev/null 2>&1; then
                record build "${variant}" SKIP "SKIP_BUILD=1, using existing images"
            else
                record build "${variant}" FAIL "SKIP_BUILD=1 but images are missing"
            fi
            continue
        fi
        log "▶ build/${variant}"
        if "${DIR}/run.sh" build "${variant}" > "${SUITE_DIR}/logs/build-${variant}.log" 2>&1; then
            record build "${variant}" PASS "$(grep -m2 'Building' "${SUITE_DIR}/logs/build-${variant}.log" | sed 's/.*Building //' | tr '\n' ';')"
        else
            record build "${variant}" FAIL "see logs/build-${variant}.log"
        fi
    done
}

# ── 3–6 e2e runs ─────────────────────────────────────────────
# run_case STAGE LABEL GENS HOSTS SCENARIO VARIANT SECONDS [EXTRA_ENV...]
run_case() {
    local stage="$1" label="$2" gens="$3" hosts="$4" scenario="$5" variant="$6" secs="$7"
    shift 7
    local envs=(GENS="${gens}" HOSTS="${hosts}" SCENARIO="${scenario}" MEASURE_SECONDS="${secs}" RESULTS_DIR="${RUNS}")
    case "${variant}" in
        baseline)    envs+=(GEN_IMAGE="${BASE_GEN}" HOST_IMAGE="${BASE_HOST}") ;;
        candidate)   envs+=(GEN_IMAGE="${CAND_GEN}" HOST_IMAGE="${CAND_HOST}") ;;
        hosts-first) envs+=(GEN_IMAGE="${BASE_GEN}" HOST_IMAGE="${CAND_HOST}") ;;
        gens-first)  envs+=(GEN_IMAGE="${CAND_GEN}" HOST_IMAGE="${BASE_HOST}") ;;
        mixed-mesh)  envs+=(GEN_IMAGE="${CAND_GEN}" HOST_IMAGE="${CAND_HOST}" GEN_1_IMAGE="${BASE_GEN}" HOST_1_IMAGE="${BASE_HOST}") ;;
    esac
    envs+=("$@")
    log "▶ ${stage}/${label} (${gens}g×${hosts}h ${scenario}, ${variant}, ${secs}s)"
    local rc=0 json="${RUNS}/${label}.json" detail result
    env "${envs[@]}" "${DIR}/run.sh" run "${label}" > "${SUITE_DIR}/logs/${label}.log" 2>&1 || rc=$?
    if [[ -f "${json}" ]]; then
        detail="$(jq -r --slurp '.[0] as $r | "mesh \(($r.per_block.mesh_bytes // 0) / 1024 | floor) KiB/block, lag \($r.max_lag_blocks), checks: \($r.checks | to_entries | map(select(.value == false) | .key) | if length == 0 then "all ok" else "FAILED " + join(",") end)"' "${json}")"
    else
        detail="no result; see logs/${label}.log"
    fi
    result=PASS
    if (( rc != 0 )); then
        # A baseline failure is pre-existing behaviour, not something this change broke.
        [[ "${variant}" == baseline ]] && result=WARN || result=FAIL
        # Likewise when the candidate fails only checks that its baseline also failed.
        local basejson="${RUNS}/${label%-candidate}-baseline.json"
        if [[ "${result}" == FAIL && "${label}" == *-candidate && -f "${basejson}" && -f "${json}" ]]; then
            if jq -es 'def failed: .checks | to_entries | map(select(.value == false) | .key) | sort;
                       (.[0] | failed) as $cand | (.[1] | failed) as $base |
                       ($cand | length) > 0 and ((($cand - $base) | length) == 0)' \
                       "${json}" "${basejson}" >/dev/null; then
                result=WARN
                detail="${detail} — same failures on baseline, pre-existing"
            fi
        fi
        tail -8 "${SUITE_DIR}/logs/${label}.log" | sed 's/^/          /'
    fi
    record "${stage}" "${label}" "${result}" "${detail}"
}

ab_case() {  # ab_case STAGE NAME GENS HOSTS SCENARIO SECONDS [EXTRA_ENV...]
    local stage="$1" name="$2"; shift 2
    local gens="$1" hosts="$2" scenario="$3" secs="$4"; shift 4
    run_case "${stage}" "${name}-baseline"  "${gens}" "${hosts}" "${scenario}" baseline  "${secs}" "$@"
    run_case "${stage}" "${name}-candidate" "${gens}" "${hosts}" "${scenario}" candidate "${secs}" "$@"
    echo "${name}" >> "${SUITE_DIR}/pairs"
}

e2e() {
    : > "${SUITE_DIR}/pairs"
    if stage_failed build; then
        record smoke candidate-3x3 SKIP "build failed"; return
    fi
    want smoke && run_case smoke smoke 3 3 steady candidate 60 WARMUP_SECONDS=15
    if stage_failed smoke; then
        warn "smoke failed: skipping benchmark, regression and compat stages"
        return
    fi

    if want benchmark; then
    ab_case benchmark bench-3x3 3 3 steady "${BENCH_SECONDS}"
    if [[ "${PROFILE}" == full ]]; then
        ab_case benchmark bench-1x1 1 1 steady "${BENCH_SECONDS}"
        ab_case benchmark bench-1x3 1 3 steady "${BENCH_SECONDS}"
        ab_case benchmark bench-3x3-highload 3 3 steady "${BENCH_SECONDS}" LOAD_INTERVAL=0.05
    fi

    fi

    if want regression; then
        ab_case regression restart-3x3 3 3 restart "${REG_SECONDS}"
        [[ "${PROFILE}" == full ]] && ab_case regression freeze-3x3 3 3 freeze "${REG_SECONDS}"
    fi

    if want compat; then
        run_case compat hosts-first 3 3 steady hosts-first "${REG_SECONDS}"
        run_case compat gens-first 3 3 steady gens-first "${REG_SECONDS}"
        run_case compat mixed-mesh 3 3 steady mixed-mesh "${REG_SECONDS}"
    fi
}

# ── 7 realchain ──────────────────────────────────────────────
# The candidate indexing a historical range from a real Ethereum RPC. No baseline
# run: the numbers are tracked night over night, a failed run gates.
realchain_case() {
    local name="$1" start="${SECONDS}"
    local out="${SUITE_DIR}/realchain/${name}" logfile="${SUITE_DIR}/logs/${name}.log"
    log "▶ realchain/${name}"
    if env OUT_DIR="${out}" GEN_IMAGE="${CAND_GEN}" HOST_IMAGE="${CAND_HOST}" "${DIR}/${name}.sh" > "${logfile}" 2>&1 \
        && [[ -f "${out}/result.json" ]]; then
        record realchain "${name}" PASS "$(( SECONDS - start ))s, see realchain/${name}/results.md"
    else
        record realchain "${name}" FAIL "$(( SECONDS - start ))s, see logs/${name}.log"
        tail -8 "${logfile}" | sed 's/^/          /'
    fi
}

realchain() {
    if [[ -z "${GETH_RPC_URL:-}" ]]; then record realchain all SKIP "GETH_RPC_URL not set"; return; fi
    if stage_failed build; then record realchain all SKIP "build failed"; return; fi
    realchain_case blocktime
    realchain_case readload
}

# ── 8 report ─────────────────────────────────────────────────
report() {
    local md="${SUITE_DIR}/REPORT.md" pair rows="${SUITE_DIR}/deltas.jsonl" verdict=READY reasons=()
    : > "${rows}"

    while read -r pair; do
        [[ -f "${RUNS}/${pair}-baseline.json" && -f "${RUNS}/${pair}-candidate.json" ]] || continue
        "${DIR}/run.sh" compare-json "${RUNS}/${pair}-baseline.json" "${RUNS}/${pair}-candidate.json" \
            | jq -c --arg p "${pair}" '.[1:][] | {pair: $p, metric: .[0], baseline: .[1], candidate: .[2], delta: .[3], verdict: .[4]}' >> "${rows}"
    done < <(cat "${SUITE_DIR}/pairs" 2>/dev/null)

    # Correctness gates: anything FAIL. Performance gate: the 3×3 mesh must move fewer bytes per block.
    # A candidate failure gates the release only when its baseline passed the same run.
    local gating
    gating="$(awk -F'\t' '
        NR == FNR { if ($2 ~ /-baseline$/) { n = $2; sub(/-baseline$/, "", n); base[n] = $3 } next }
        $3 == "FAIL" {
            n = $2; sub(/-candidate$/, "", n)
            if (n != $2 && (base[n] == "FAIL" || base[n] == "WARN")) next
            print $1 "/" $2
        }' "${STATUS}" "${STATUS}" | paste -sd, -)"
    if [[ -n "${gating}" ]]; then
        verdict="NOT READY"; reasons+=("${gating} failed")
    fi
    local gate
    gate="$(jq -r 'select(.pair == "bench-3x3" and .metric == "mesh bytes/block") | .verdict' "${rows}")"
    if [[ "${REQUIRE_IMPROVEMENT}" == 1 && "${gate}" != better ]]; then
        verdict="NOT READY"; reasons+=("bench-3x3 mesh bytes/block is '${gate:-not measured}', expected 'better'")
    fi
    if jq -e 'select(.verdict == "REGRESSION")' "${rows}" >/dev/null 2>&1; then
        verdict="NOT READY"; reasons+=("a check passes on baseline but fails on candidate")
    fi

    {
        echo "# E2E-multi release report"
        echo
        echo "- **Verdict: ${verdict}**$( (( ${#reasons[@]} )) && printf ' (%s)' "$(printf '%s; ' "${reasons[@]}" | sed 's/; $//')")"
        echo "- Date: $(date -u +%Y-%m-%dT%H:%MZ), profile: ${PROFILE}, noise threshold: ±${NOISE_PCT}%"
        echo "- Machine: $(docker info --format '{{.NCPU}} CPUs, {{.MemTotal}} bytes for Docker, {{.OperatingSystem}}')"
        local img id
        for img in "${BASE_GEN}" "${BASE_HOST}" "${CAND_GEN}" "${CAND_HOST}"; do
            id="$(docker image inspect -f '{{.Id}} (built {{.Created}})' "${img}" 2>/dev/null | tr -d '\n')"
            echo "- \`${img}\`: ${id:-missing}"
        done
        echo
        echo "## Gates"
        echo
        echo "| stage | test | result | detail |"
        echo "|---|---|---|---|"
        awk -F'\t' '{printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4}' "${STATUS}"
        echo
        echo "## Improved (candidate vs baseline)"
        echo
        jq -r 'select(.verdict == "better") | "- \(.pair): \(.metric) \(.baseline) → \(.candidate) (\(.delta))"' "${rows}"
        echo
        echo "## Got worse"
        echo
        jq -r 'select(.verdict == "worse" or .verdict == "REGRESSION") | "- \(.pair): \(.metric) \(.baseline) → \(.candidate) (\(.delta))"' "${rows}"
        echo
        while read -r pair; do
            [[ -f "${RUNS}/${pair}-baseline.json" && -f "${RUNS}/${pair}-candidate.json" ]] || continue
            echo "## ${pair}"
            echo
            "${DIR}/run.sh" compare-md "${RUNS}/${pair}-baseline.json" "${RUNS}/${pair}-candidate.json"
            echo
        done < <(cat "${SUITE_DIR}/pairs" 2>/dev/null)
        local cf
        for cf in "${RUNS}"/smoke.json "${RUNS}"/bench-3x3-candidate.json; do
            [[ -f "${cf}" ]] || continue
            if "${DIR}/run.sh" car-md "${cf}" > /tmp/car-md.$$ 2>/dev/null && [[ -s /tmp/car-md.$$ ]]; then
                echo "## CAR exchange — $(basename "${cf}" .json)"; echo; cat /tmp/car-md.$$; echo
            fi
            rm -f /tmp/car-md.$$
        done
        if ls "${RUNS}"/{hosts-first,gens-first,mixed-mesh}.json >/dev/null 2>&1; then
            echo "## Mixed-version meshes"
            echo
            echo "| run | pass | mesh KiB/block | syncDAG/block | carFetchMissed/block | max lag |"
            echo "|---|---|---:|---:|---:|---:|"
            for f in "${RUNS}"/{hosts-first,gens-first,mixed-mesh}.json; do
                [[ -f "${f}" ]] && jq -r '"| \(.label) | \(.pass) | \((.per_block.mesh_bytes // 0) / 1024 | floor) | \(if .blocks > 0 then ((.stats_total.syncDAGCalls // 0) / .blocks * 100 | round / 100) else "-" end) | \(if .blocks > 0 and .stats_total.carFetchMissed != null then (.stats_total.carFetchMissed / .blocks * 100 | round / 100) else "-" end) | \(.max_lag_blocks) |"' "${f}"
            done
            echo
        fi
        local rc
        for rc in blocktime readload; do
            [[ -f "${SUITE_DIR}/realchain/${rc}/results.md" ]] || continue
            echo "## Real chain — ${rc} (candidate)"
            echo
            # demote the script's own headings below this one
            sed 's/^#/###/' "${SUITE_DIR}/realchain/${rc}/results.md"
            echo
        done
        echo "Raw results: \`runs/*.json\`, \`realchain/*/result.json\`; per-node logs: \`runs/*-logs/\`; stage logs: \`logs/\`."
    } > "${md}"

    jq -s --arg verdict "${verdict}" '{verdict: $verdict, deltas: .}' "${rows}" > "${SUITE_DIR}/summary.json"

    echo
    echo -e "${BOLD}════════ improved ════════${NC}"
    jq -r 'select(.verdict == "better") | "  \(.pair): \(.metric) \(.baseline) → \(.candidate) (\(.delta))"' "${rows}"
    echo -e "${BOLD}════════ got worse ═══════${NC}"
    jq -r 'select(.verdict == "worse" or .verdict == "REGRESSION") | "  \(.pair): \(.metric) \(.baseline) → \(.candidate) (\(.delta))"' "${rows}"
    echo -e "${BOLD}════════ gates ═══════════${NC}"
    awk -F'\t' '{printf "  %-5s %s/%s\n", $3, $1, $2}' "${STATUS}"
    echo
    if [[ "${verdict}" == READY ]]; then
        echo -e "${GREEN}${BOLD}VERDICT: READY${NC}"
    else
        echo -e "${RED}${BOLD}VERDICT: NOT READY${NC}: $(printf '%s; ' "${reasons[@]}" | sed 's/; $//')"
    fi
    echo "Report: ${md}"
    [[ "${verdict}" == READY ]]
}

# REPORT_ONLY=1 SUITE_DIR=results/suite-… ./suite.sh rebuilds the report of an earlier suite.
if [[ "${REPORT_ONLY:-0}" == 1 ]]; then report; exit; fi

: > "${STATUS}"
preflight
want unit  && { log "── 1 unit";  unit; }
want build && { log "── 2 build"; build; }
log "── 3–6 e2e";  e2e
want realchain && { log "── 7 realchain"; realchain; }
log "── 8 report"; report
