# Shinzo E2E conn-limit testing

How many libp2p connections does one generator accept from 1, 2, 3 or 4
clients that all reach it from the **same source IP**?

In Kubernetes, every in-cluster host reaches a generator through one SNAT
address, so they share libp2p's per-IP budgets:

| Limit | libp2p default | Config that changes it |
|---|---|---|
| Concurrent connections per IPv4 address (IPv6 /56) | 8 | `defradb.p2p.max_conns_per_ip` |
| New-connection rate per IPv4 address | burst 16, then 1 per 5s | scales with `max_conns_per_ip` (2× burst) |
| Both, for trusted networks | — | `defradb.p2p.allowlist_cidrs` exempts them |

Once the 8 are used up, the 9th dialer sees `failed to negotiate security protocol: EOF`.

## Run it

```bash
./run.sh            # build both images from local sources, then run the matrix
./run.sh build      # only build
./run.sh run        # only run (images must exist)
./run.sh ceiling    # 4 allowlisted clients x 250 held connections vs the connection manager
./run.sh down       # clean up
```

`ceiling` samples the target's connected-peer count every 3s into
`results/ceiling-<timestamp>.tsv`. go-p2p hardcodes the connection manager at
low 100 / high 400 / 20s grace, so today the count climbs to 1000 and then
drops to 100: live connections get pruned, allowlisted or not. Tune it with
`CEILING_CLIENTS`, `CEILING_PER_PROBE` and `CEILING_SETTLE`.

Results go to `results/<timestamp>.jsonl` (one line per case, with every
probe's raw counts and refusal reasons) and `results/<timestamp>.md` (the table).
The script exits 1 if any case falls outside its expected range.

## What runs

| Container | Role |
|---|---|
| `cl-anvil` | local chain, so the generator starts |
| `cl-target` | the generator under test, `172.31.0.10`, production resource-manager budgets |
| `cl-nat` | holds `172.31.0.20`, the shared "SNAT address" |
| `cl-probe-N` | connection probes; shared-IP probes join `cl-nat`'s network namespace |

Each probe opens `PER_PROBE` (default 40) connections, each from a fresh peer
identity as a separate pod would have, and reports how many the target kept:

- **hold**: connections stay open, which measures the concurrent cap
- **churn**: each connection closes once it's accepted, which measures the rate limit

Target configs: `default` (neither option set), `cap4` (`max_conns_per_ip=4`),
and `allowlist` (`allowlist_cidrs=172.31.0.20/32`). The target restarts before
every case, so per-IP counters and rate buckets start empty.

A **distinct-IP control** gives each probe its own address under the
`default` config. This shows the limit is per address: 4 clients on 4 IPs get
4 × 8.

## Expected results

| config | ip | hold | churn |
|---|---|---|---|
| default | shared | 8 for any N | ~16 for any N |
| cap4 | shared | 4 | ~8 |
| allowlist | shared | all N × 40 | all N × 40 |
| default | distinct | 8 × N | ~16 × N |

The churn ranges allow a little slack for the 0.2/s refill while a case runs.

## Built only from local sources

`Dockerfile` here builds both images from a context that `run.sh` assembles:

- the `shinzo-indexer-client` **working tree**, so uncommitted changes are tested
- `DEFRADB_REF` (default `dvncan/connection-mgr-ratelimit`) archived from the
  local `defradb` checkout and wired in with a `replace`
- `probe/`

Only the Go and Debian base images and anvil are pulled.

## Env

`DEFRADB_REF`, `DEFRADB_SRC`, `CLIENT_SRC`, `COUNTS="1 2 3 4"`,
`CONFIGS="default cap4 allowlist"`, `MODES="hold churn"`, `CONTROL=1`,
`PER_PROBE=40`, `KEEP=1`.

To see the bug the rate-limit fix addresses, build against the merged PR
without it and run the allowlist cases:

```bash
DEFRADB_REF=56c39929 ./run.sh build
CONFIGS=allowlist ./run.sh run      # churn caps at ~16 despite the allowlist
```
