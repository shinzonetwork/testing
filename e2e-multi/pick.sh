#!/usr/bin/env bash
set -uo pipefail

# ───────────────────────────────────────────────────────────────
# Interactive front end for the e2e-multi harness.
#
#   ./pick.sh           choose images, tests and the gating metric, then run
#   ./pick.sh review    browse finished runs, with what looks off highlighted
#
# It shells out to run.sh and suite.sh and prints every command before running
# it, so the CLI stays the thing you learn. No dependencies beyond the harness.
# ───────────────────────────────────────────────────────────────

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="${DIR}/results"
REPOS=(shinzo-indexer shinzo-host)

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[0;31m'; GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'

# Menus are drawn while their return value is being captured by $( ), so every
# piece of UI goes to the terminal directly, never to stdout.
# -w /dev/tty passes even where the device cannot be opened, so try a write.
if { printf '' > /dev/tty; } 2>/dev/null; then TTY=/dev/tty; IN=/dev/tty; else TTY=/dev/stderr; IN=/dev/stdin; fi
say()   { echo -e "$*" > "${TTY}"; }
head2() { { echo; echo -e "${BOLD}$*${NC}"; } > "${TTY}"; }
die()   { echo -e "${RED}$*${NC}" >&2; exit 1; }

# ── image catalogue ──────────────────────────────────────────
# A role needs the same defradb ref in both repos, so only refs present in both
# are offered. That is the mismatch that silently invalidated a run: indexer on
# one commit, host left on an older one by a failed build.
CAT_TAGS=(); CAT_LABELS=()

ref_of()   { docker image inspect "$1" --format '{{index .Config.Labels "e2e.defradb_ref"}}' 2>/dev/null; }
arch_of()  { docker image inspect "$1" --format '{{.Architecture}}' 2>/dev/null; }
built_at() { docker image inspect "$1" --format '{{.Created}}' 2>/dev/null | cut -c1-16 | tr 'T' ' '; }

# Every tag present on BOTH repos is offered, labelled or not — an unlabelled image is
# still usable, and hiding it is what sends people off to rebuild something they have.
# A role is a pointer at one of these pairs, never a rebuild.
build_catalogue() {
    CAT_TAGS=(); CAT_LABELS=()
    local tag ref arch subject
    while read -r tag; do
        [[ -n "${tag}" ]] || continue
        docker image inspect "shinzo-host:${tag}" >/dev/null 2>&1 || continue
        ref="$(ref_of "shinzo-indexer:${tag}")"
        arch="$(arch_of "shinzo-indexer:${tag}")"
        subject=""
        [[ -n "${ref}" ]] && subject="$(git -C "${DIR}/../../defradb" log -1 --format=%s "${ref#worktree-}" 2>/dev/null | cut -c1-38)"
        CAT_TAGS+=("${tag}")
        CAT_LABELS+=("$(printf '%-26s %-11s %-9s %-38s %s' \
            "${tag}" "${ref:-unlabelled}" "${arch}" "${subject:-—}" "$(built_at "shinzo-indexer:${tag}")")")
    done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep '^shinzo-indexer:' | cut -d: -f2 | sort)
}

assign_role() {  # assign_role <role> <source tag>
    local role="$1" tag="$2" repo ref
    [[ "${tag}" == "${role}" ]] && return 0   # already pointing there
    for repo in "${REPOS[@]}"; do
        say "${DIM}\$ docker tag ${repo}:${tag} ${repo}:${role}${NC}"
        docker tag "${repo}:${tag}" "${repo}:${role}" >/dev/null || die "tagging ${repo}:${role} failed"
        # keep the source reachable by its ref, so a role move never strands an image
        ref="$(ref_of "${repo}:${tag}")"
        [[ -n "${ref}" ]] && docker tag "${repo}:${tag}" "${repo}:defradb-${ref}" >/dev/null 2>&1
    done
}

verify_pair() {  # verify_pair <role> → prints the shared ref, or fails
    local role="$1" repo ref first=""
    for repo in "${REPOS[@]}"; do
        ref="$(ref_of "${repo}:${role}")"
        [[ -n "${ref}" ]] || { echo -e "${YELLOW}${repo}:${role} has no defradb label${NC}" >&2; ref="(unlabelled)"; }
        if [[ -z "${first}" ]]; then first="${ref}"
        elif [[ "${ref}" != "${first}" ]]; then
            echo -e "${RED}MISMATCH ${role}: ${REPOS[0]}=${first} ${repo}=${ref}${NC}" >&2
            return 1
        fi
    done
    echo "${first}"
}

menu() {  # menu "title" item... → echoes the chosen index (1-based) on stdout
    local title="$1"; shift
    local i=1 choice
    head2 "${title}"
    for item in "$@"; do printf '  %2d) %s\n' "${i}" "${item}" > "${TTY}"; i=$((i + 1)); done
    while :; do
        printf '  choice [1]: ' > "${TTY}"
        read -r choice < "${IN}" || choice=1
        choice="${choice:-1}"
        [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= $# )) && { echo "${choice}"; return 0; }
        echo "  pick 1-$#" > "${TTY}"
    done
}

# ── run flow ─────────────────────────────────────────────────
pick_ref() {  # pick_ref <role> → echoes the chosen source tag
    local role="$1" opts=() n
    build_catalogue
    (( ${#CAT_TAGS[@]} > 0 )) || die "no images built yet. Try: DEFRADB_REF=<sha> ./run.sh build candidate"
    opts=("${CAT_LABELS[@]}" "build a new defradb ref…")
    n="$(menu "${role^} image?   (tag / defradb / arch / commit / built)" "${opts[@]}")"
    if (( n > ${#CAT_TAGS[@]} )); then
        local commits=() line sha
        while read -r line; do commits+=("${line}"); done < <(git -C "${DIR}/../../defradb" log --oneline -15 | cut -c1-70)
        n="$(menu "which defradb commit?" "${commits[@]}")"
        sha="$(echo "${commits[$((n - 1))]}" | cut -d' ' -f1)"
        say "${DIM}\$ DEFRADB_REF=${sha} ./run.sh build ${role}${NC}"
        DEFRADB_REF="${sha}" "${DIR}/run.sh" build "${role}" || die "build failed"
        echo "${role}"
    else
        echo "${CAT_TAGS[$((n - 1))]}"
    fi
}

run_flow() {
    local base_tag cand_tag n stages profile gate min_pct suite_dir base_ref cand_ref
    base_tag="$(pick_ref baseline)"  || exit 1
    cand_tag="$(pick_ref candidate)" || exit 1
    assign_role baseline  "${base_tag}"
    assign_role candidate "${cand_tag}"

    head2 "roles"
    base_ref="$(verify_pair baseline)"; cand_ref="$(verify_pair candidate)"
    printf '  baseline  %-26s defradb=%s\n  candidate %-26s defradb=%s\n' "${base_tag}" "${base_ref}" "${cand_tag}" "${cand_ref}" > "${TTY}"
    verify_pair baseline >/dev/null  || die "fix the baseline pair before running"
    verify_pair candidate >/dev/null || die "fix the candidate pair before running"
    [[ "${base_tag}" != "${cand_tag}" ]] || say "${YELLOW}  note: both roles are the same build — the comparison will show no difference${NC}"

    n="$(menu "Tests?" \
        "smoke                 ~4 min   mesh forms, replicates, CAR pull runs" \
        "smoke + benchmark     ~15 min  the A/B you quote" \
        "+ regression          ~30 min  restart / freeze under load" \
        "full suite            ~110 min unit, compat, every topology")"
    case "${n}" in
        1) stages=smoke;                          profile=quick ;;
        2) stages=smoke,benchmark;                profile=quick ;;
        3) stages=smoke,benchmark,regression;     profile=quick ;;
        4) stages=unit,build,smoke,benchmark,regression,compat; profile=full ;;
    esac

    # The gate decides PASS/FAIL. Preset to bytes/block, which is wrong for a
    # change whose effect is elsewhere — a CAR-fallback fix moves miss rate, not bytes.
    n="$(menu "Which metric decides pass/fail?" \
        "mesh bytes/block      total P2P traffic — egress and billing" \
        "CAR miss rate         heads that fell back to a DAG walk" \
        "syncDAG/block         DAG walks per block" \
        "host rx bytes/block   what each partner downloads" \
        "cpu ms/block          CPU across all nodes" \
        "max host lag          how far the slowest host fell behind" \
        "checks only           no metric gate, correctness must pass")"
    case "${n}" in
        1) gate=mesh_bytes ;; 2) gate=miss_rate ;; 3) gate=syncdag_per_block ;;
        4) gate=host_rx_bytes ;; 5) gate=cpu_ms ;; 6) gate=max_lag ;; 7) gate=none ;;
    esac
    if [[ "${gate}" != none ]]; then
        printf '  minimum improvement %% [5]: ' > "${TTY}"; read -r min_pct < "${IN}"; min_pct="${min_pct:-5}"
    else
        min_pct=0
    fi

    suite_dir="${RESULTS}/suite-$(date +%Y%m%d-%H%M%S)"
    head2 "command"
    say "${CYAN}\$ SUITE_DIR=${suite_dir} SKIP_BUILD=1 STAGES=${stages} PROFILE=${profile} \\
    GATE_METRIC=${gate} GATE_MIN_PCT=${min_pct} ./suite.sh${NC}"
    printf '  [enter] run, [q] quit: ' > "${TTY}"; read -r go < "${IN}"
    [[ "${go}" == q ]] && exit 0
    SUITE_DIR="${suite_dir}" SKIP_BUILD=1 STAGES="${stages}" PROFILE="${profile}" \
        GATE_METRIC="${gate}" GATE_MIN_PCT="${min_pct}" "${DIR}/suite.sh"
}

# ── review flow ──────────────────────────────────────────────
# Flags anything that would make a result untrustworthy or interesting, so a
# newcomer does not have to know which of thirty numbers matters.
highlight() {  # highlight <result.json>
    jq -r '
      def pct(x): if x == null then "-" else ((x * 100) | round | tostring) + "%" end;
      ([.nodes[] | select(.role == "host")]) as $h |
      ([$h[] | .car.miss_rate // empty] | if length == 0 then null else (add / length) end) as $miss |
      ([$h[] | .fetch_outcomes | to_entries[]] | group_by(.key)
        | map({k: .[0].key, v: (map(.value) | add)}) | sort_by(-.v) | .[0]) as $top |
      "  \(.label): \(.topology.gens)g×\(.topology.hosts)h \(.scenario), \(.blocks) blocks, \(if .pass then "PASS" else "FAIL" end)",
      "    mesh \((.per_block.mesh_bytes // 0) / 1024 | floor) KiB/block · miss \(pct($miss)) · lag \(.max_lag_blocks) · catch-up \(.catchup_seconds)s",
      (if .pass | not then "    ⚠ failed checks: \(.checks | to_entries | map(select(.value == false) | .key) | join(", "))" else empty end),
      (if .checks.car_invariants == false then "    ⚠ CAR counter invariants broken — treat these numbers as indicative only" else empty end),
      (if .checks.parity == false then "    ⚠ nodes hold different documents" else empty end),
      (if .max_lag_blocks > 10 then "    ⚠ lag \(.max_lag_blocks) blocks — nodes could not keep up" else empty end),
      (if $miss != null and $miss > 0.05 then "    ⚠ \(pct($miss)) of heads fell back to DAG walks" else empty end),
      (if $top != null and ($top.k | test("QueueFull|ResourceLimited|RequestFailed|Timeout")) then "    ⚠ dominant CAR outcome is \($top.k)=\($top.v)" else empty end)
    ' "$1"
}

review_flow() {
    local dirs=() d n chosen runs=() f
    while read -r d; do dirs+=("${d}"); done < <(ls -dt "${RESULTS}"/suite-*/ 2>/dev/null | head -20)
    (( ${#dirs[@]} > 0 )) || die "no suite results in ${RESULTS}"
    local labels=()
    for d in "${dirs[@]}"; do
        labels+=("$(printf '%-34s %s' "$(basename "${d}")" "$(jq -r '.verdict // "—"' "${d}/summary.json" 2>/dev/null)")")
    done
    n="$(menu "Which run?" "${labels[@]}")"
    chosen="${dirs[$((n - 1))]}"

    head2 "$(basename "${chosen}")"
    [[ -f "${chosen}/status.tsv" ]] && awk -F'\t' '{printf "  %-5s %s/%s — %s\n", $3, $1, $2, substr($4, 1, 50)}' "${chosen}/status.tsv"

    head2 "runs"
    while read -r f; do runs+=("${f}"); highlight "${f}"; done < <(ls "${chosen}"/runs/*.json 2>/dev/null)

    if (( ${#runs[@]} >= 2 )); then
        head2 "compare two?"
        local names=()
        for f in "${runs[@]}"; do names+=("$(basename "${f}" .json)"); done
        names+=("skip")
        n="$(menu "baseline side" "${names[@]}")"; (( n > ${#runs[@]} )) && return 0
        local a="${runs[$((n - 1))]}"
        n="$(menu "candidate side" "${names[@]}")"; (( n > ${#runs[@]} )) && return 0
        local b="${runs[$((n - 1))]}"
        say "${DIM}\$ ./run.sh compare-md ${a} ${b}${NC}"
        "${DIR}/run.sh" compare-md "${a}" "${b}"
    fi
    [[ -f "${chosen}/REPORT.md" ]] && say "\n  full report: ${chosen}/REPORT.md"
}

case "${1:-run}" in
    run)    run_flow ;;
    review) review_flow ;;
    *) echo "usage: $0 [run|review]"; exit 1 ;;
esac
