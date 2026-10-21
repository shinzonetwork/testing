# Shinzo E2E multi-node testing

A full P2P mesh of up to three generators and three hosts, all replicating a
local anvil chain under steady transaction load. Each run measures libp2p
traffic, CPU, memory, disk and replication lag, checks that every node ended up
with the same data, and writes the result to `results/<label>.json`.

No ShinzoHub, no SourceHub, no real chain: the topology is wired directly, so
runs are repeatable and two image sets can be compared like for like.

## Run it

```bash
./run.sh build candidate      # shinzo-{indexer,host}:candidate from the working trees
./run.sh run my-label         # one measured run → results/my-label.json
./run.sh down                 # stop and wipe state
```

Or compare two builds end to end:

```bash
./run.sh build baseline       # from each client repo's BASELINE_REF (default HEAD)
./run.sh build candidate
./run.sh ab                   # baseline run, candidate run, side-by-side compare
```

For a guided run, `./pick.sh` lets you choose images, tests and the gating
metric from menus, and prints every `run.sh` / `suite.sh` command before it
runs it. `./pick.sh review` browses finished runs.

## Prerequisites

- Docker with Compose v2, plus `curl`, `jq`, `awk` and `git`
- The client repos checked out as siblings of this repo, and `defradb` next to
  them if you build against a specific DefraDB ref:
  ```
  some-dir/
    shinzo-indexer-client/
    shinzo-host-client/
    defradb/              # optional, see DEFRADB_REF
    e2e/
      e2e-multi/          ← this directory
  ```

Images are built locally and never pushed.

## Verify it works

A run passes when all of these hold:

| Check | Meaning |
|---|---|
| `mesh` | every node connected to every other node |
| `replicated` | each host caught up to the generators within `LAG_TOLERANCE` blocks |
| `parity` | all nodes hold the same documents for the measured range |
| `views_populated` | the host's lens views produced data from the seeded logs |
| `no_drops` | no replication updates were dropped |
| `no_import_failures` | no node failed to import a received block |
| `car_invariants` | block-exchange counters are consistent (steady scenario only) |

The run prints a summary line ending in `PASS` or `FAIL`; the full metrics and
the per-check results are in the JSON. To look at the history of runs:

```bash
./report.sh open      # builds results/dashboard.html (self-contained) and opens it
```

## What runs

| Service | Role | Network |
|---|---|---|
| `anvil` | local Ethereum chain | `chain-net` |
| `loadgen` | deploys log emitters and drives transactions into anvil (profile `load`) | `chain-net` |
| `gen-1` … `gen-3` | generators: index anvil into DefraDB, publish over libp2p | `chain-net`, `p2p-net` |
| `host-1` … `host-3` | hosts: replicate from the generators, serve views | `p2p-net` |

The two networks are deliberately separate. Generators bind libp2p to their
`p2p-net` address, so the `p2p-net` interface counters are P2P traffic and
nothing else — JSON-RPC indexing traffic stays on `chain-net`.

Every node dials every other node at startup; `GENS` and `HOSTS` choose how
many of each are started.

## Commands

| Command | What it does |
|---|---|
| `./run.sh build baseline\|candidate` | build test images (`:baseline` from `BASELINE_REF`, `:candidate` from the working trees) |
| `./run.sh cycle` | promote `:candidate` to `:baseline` (old one kept as `:baseline-prev`), then build a new candidate |
| `./run.sh run [label]` | one measured run → `results/<label>.json` |
| `./run.sh ab` | baseline run, candidate run, compare |
| `./run.sh compare A.json B.json` | metrics side by side; exits 1 unless both pass and B's mesh bytes/block is `MIN_REDUCTION_PCT` lower |
| `./run.sh compare-md A.json B.json` | same table as markdown, never fails |
| `./run.sh car-md RESULT.json` | block-exchange table for one run, as markdown |
| `./run.sh down` | tear everything down |

## Configuration

Everything is set through environment variables. The ones worth knowing about:

- **`GENS` / `HOSTS`** (default `3` / `3`) — topology, 1–3 of each.
- **`SCENARIO`** (default `steady`) — `steady`, `restart` (the last host is
  restarted mid-window) or `freeze` (the last host is paused for
  `FREEZE_SECONDS`, default 20).
- **`GEN_IMAGE` / `HOST_IMAGE`** — images for all generators / hosts, default
  `shinzo-{indexer,host}:candidate`. **`GEN_n_IMAGE` / `HOST_n_IMAGE`** override
  a single node, for mixed-version meshes.
- **`BASELINE_GEN_IMAGE` / `BASELINE_HOST_IMAGE`** — what `ab` compares against,
  default `shinzo-{indexer,host}:baseline`. Point these at a published release
  to compare against it without building.
- **`DEFRADB_REF`** — build against that commit of the local DefraDB checkout
  (`DEFRADB_SRC`, default `../../defradb`) instead of the version pinned in
  `go.mod`, or `WORKTREE` for its uncommitted changes. Client code still comes
  from the working trees, so two such images differ only in DefraDB.
- **`MEASURE_SECONDS`** (default `180`) — the measured window. Keep it a multiple
  of 30: DefraDB reports P2P counters every 30s and resets them.
- **`WARMUP_SECONDS`** (default `30`) — load runs this long before the window opens.
- **`LOAD_ACCOUNTS` / `LOAD_INTERVAL`** (default `4` / `0.2`) — load is
  accounts × (1 / interval) transactions per second.
- **`GEN_ACCEPT_INCOMING`** (default `false`) — let generators merge from each other.
- **`NOISE_PCT`** (default `5`) — deltas smaller than this are reported as "same".
- **`MIN_REDUCTION_PCT`** (default `0`) — the `compare` threshold on mesh bytes/block.
- **`KEEP=1`** — leave the containers up after a run for poking at.

Timeouts (`PEER_TIMEOUT`, `MESH_TIMEOUT`, `CATCHUP_TIMEOUT`, `PARITY_TIMEOUT`)
and `LAG_TOLERANCE` rarely need changing.

## Release suite

`suite.sh` runs every check in the harness, baseline against candidate, and
ends with what improved, what got worse and a release verdict:

1. **unit** — `go vet` + `go test` for the DefraDB p2p package, indexer and host
2. **build** — `:baseline` and `:candidate`
3. **smoke** — candidate 3×3 mesh, short window; later e2e stages are skipped if it fails
4. **benchmark** — baseline vs candidate: traffic, CPU, memory, disk, lag
5. **regression** — restart (and freeze, on the full profile) under load
6. **compat** — mixed-version meshes in every rolling-upgrade order
7. **realchain** — `blocktime.sh` and `readload.sh` with the candidate images
   against a real Ethereum RPC; skipped unless `GETH_RPC_URL` is set
8. **report** — `REPORT.md` and `summary.json` in the suite directory

```bash
./suite.sh                     # PROFILE=quick, ~45 min
PROFILE=full ./suite.sh        # adds 1×1 / 1×3 topologies, freeze, high load
                               # and DefraDB's net integration tests, ~110 min
STAGES=build,smoke ./suite.sh  # run only these stages
REPORT_ONLY=1 SUITE_DIR=results/suite-… ./suite.sh   # rebuild an earlier report
```

Exits 0 when the verdict is READY, 1 otherwise. Other knobs: `SKIP_UNIT=1`,
`SKIP_BUILD=1`, `BASELINE_REF`, `CANDIDATE_TAG`, `BENCH_SECONDS`, `REG_SECONDS`,
`REQUIRE_IMPROVEMENT=0` (gate on failures and regressions only, not on bench-3x3
beating the baseline).

### Nightly

`.github/workflows/nightly.yml` runs the quick profile at 03:00 UTC (or on
demand): the client repos' HEADs as candidate against the published release as
baseline, without unit tests and with `REQUIRE_IMPROVEMENT=0`. The suite directory,
including `dashboard.html` and `commits.txt`, is uploaded as the run's artifact
`nightly-<run id>` (kept 90 days), and `REPORT.md` is shown in the job summary.
The workflow's header lists the secrets and variables it reads.

### Running the suite in the cloud

`terraform/` provisions a disposable GCP VM with Docker, Go and the suite's
tools installed. Copy `terraform.tfvars.example` to `terraform.tfvars`, fill in
the project and SSH key, `terraform apply`, run the suite on the VM, then
`terraform destroy`. The VM also shuts itself down after `auto_shutdown_hours`.

## Ethereum data

`loadgen.sh` deploys a small log emitter and installs an ERC20 `Transfer`
emitter at the real USDC and USDT addresses with `anvil_setCode`, so the host's
lens views — which select logs by those mainnet addresses — have something to
match. Each load account then rotates value transfers, log calls and ERC20
transfer events every `LOAD_INTERVAL` seconds. Without the load generator, anvil
produces only empty headers and the transaction, log and view paths never get
exercised.

## Directory layout

```
e2e-multi/
  docker-compose.yml          # anvil + loadgen + gen-1..3 + host-1..3
  generator.template.yaml     # generator config, filled per node at runtime
  host.yaml                   # host config
  loadgen.sh                  # transaction load against anvil
  run.sh                      # build, run, compare
  suite.sh                    # release suite
  pick.sh                     # interactive front end
  report.sh                   # results/dashboard.html
  terraform/                  # disposable GCP runner
  results/                    # run JSON, suite reports, node logs
```
