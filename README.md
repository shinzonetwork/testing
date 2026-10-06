# Shinzo E2E testing

## Run it

```bash
cp .env.sample .env
docker compose up -d --wait
```

`--wait` returns once every long-running service is healthy and every
bootstrap one-shot has exited successfully. Then:

```bash
docker compose ps           # all healthy, register-* exited 0
docker compose logs -f host
docker compose down -v      # stop and wipe state
```

## Verify it works

The end-to-end check is a GraphQL query against the **host**, which only holds
data that reached it over libp2p from the generator:

```bash
curl -s -X POST http://127.0.0.1:9281/api/v0/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ Ethereum__Mainnet__Block(limit: 3, order: {number: DESC}) { number hash timestamp } }"}'
```

Swap `Block` for `Transaction` or `Log` to see the seeder's traffic. Logs carry
topic `0xddf252ad…` — the `Transfer` signature the seeded contract emits. The
generator's own copy is on port 9181 if you want to compare the two sides.

Other useful checks:

```bash
docker compose exec shinzohub shinzohubd q ibc channel channels -o json | grep STATE_OPEN
curl -s localhost:8080/health     # generator
curl -s localhost:8081/metrics    # host
```

## What runs

| Service | Role | Host ports |
|---|---|---|
| `anvil` | local Ethereum chain, mines every `ANVIL_BLOCK_TIME`s | 8546 |
| `seeder` | deploys a log emitter and drives transactions into anvil | — |
| `sourcehub` | SourceHub node (standalone) | 27686, 9095, 1318 |
| `fund-hermes` | one-shot: tops up the relayer account from the faucet | — |
| `shinzohub` | ShinzoHub node | 26657, 1317, 9090, 8545 |
| `hermes` | IBC relayer; creates the connection, then relays | — |
| `register-ica` | one-shot: registers the ICA, waits for the channel to open | — |
| `register-policy` | one-shot: registers the Shinzo policy | — |
| `register-objects` | one-shot: registers block/logs/event/transaction | — |
| `generator` | indexes anvil into DefraDB, publishes over libp2p | 8080, 9181, 9171 |
| `host` | replicates from the generator, serves views | 8081, 9281, 9282, 9271 |

## Ordering

```
sourcehub ─healthy─▶ fund-hermes ─done─┐
shinzohub ─healthy────────────────────┴─▶ hermes ─connection─▶ register-ica
                                                                    │ done
                                                    register-policy ◀┘
                                                          │ done
                                                    register-objects
                                                          │ done
anvil ─healthy─▶ generator ─healthy─▶ host ◀──────────────┘
   └─▶ seeder
```

Every wait is a Compose condition. Hermes reports readiness by writing a marker
file once `create connection` succeeds, and `register-ica` polls for the ICA
channel to reach `STATE_OPEN` inside its own container, exiting only once it is
open — so the services after it can simply depend on it completing.

The bootstrap one-shots are safe to re-run: each waits for its transaction to
commit, retries while preconditions are still settling, and treats work that is
already done as success.

## Configuration

Everything lives in `.env`. The values worth knowing about:

- **`SHINZOHUB_SHA`** — ShinzoHub publishes only commit-SHA tags, and only from
  pushes to `main` and `develop`. The pin is a `develop` commit, because the
  demo tooling lives on that branch. There is no floating tag to track instead,
  so this needs bumping by hand.
- **`SHINZOHUB_CHAIN_ID`** — must match the `ChainID18Decimals` constant
  compiled into whichever image `SHINZOHUB_SHA` names, or the Cosmos chain id
  and the EVM chain id disagree and transactions fail in confusing ways.
  `91273001` is right for the pinned image; images from before the testnet
  switch want `91273002`. Set in one place, and flows to the hub, the Hermes
  config and the ICA scripts from there.
- **`GETH_RPC_URL` / `GETH_WS_URL`** — default to the bundled anvil. Point them
  at a real provider and stop `anvil`/`seeder` to index a live chain instead.
- **`SOURCEHUB_HOME`** — where the SourceHub home directory lives *inside* its
  container. `fund-hermes` mounts the same volume to reach the faucet key; if
  the SourceHub image changes its home path or its user, this is the knob.
- **`CHAIN_NAME` / `CHAIN_NETWORK`** — see the naming note below. Changing these
  requires `docker compose down -v`, since collection names are baked into the
  stored schema.
- **`DEFRADB_KEYRING_SECRET`** — must be non-empty; the generator refuses to
  start without one.

### A note on the image tags

The generator and host are pinned to `v0.7.0-ethereum-mainnet`, which exists
in both repos and was built from the same release. Bump them together — a
mismatched pair will disagree about schema. Not every tag in those registries
resolves, so check a tag pulls before pinning it.

## Building the generator or host from source

There are no per-PR image builds, so testing unmerged work means building it
locally. Two overlays swap a published image for a build context — use either,
or both together:

```bash
# generator from source
docker compose -f docker-compose.yaml -f docker-compose.generator-src.yaml \
  up -d --build --wait

# host from source
docker compose -f docker-compose.yaml -f docker-compose.host-src.yaml \
  up -d --build --wait

# both
docker compose -f docker-compose.yaml \
  -f docker-compose.generator-src.yaml -f docker-compose.host-src.yaml \
  up -d --build --wait
```

Whatever is currently checked out in `GENERATOR_REPO` / `HOST_REPO` is what gets
built — branch, tag or detached commit, the overlays do not care. To test a
different version, check it out there and re-run the same command with
`--build`. Both paths live in `.env` and default to the sibling checkouts
`../shinzo-generator-client` and `../shinzo-host-client`.

Drop an overlay's `-f` to go back to its published image. Nothing else about the
stack changes either way.

First builds take a while — both Dockerfiles fetch WASM runtimes and compile
with cgo, and the host also generates its playground assets. Later builds reuse
the layer cache unless `go.mod` changes.

Wipe the relevant store when swapping between builds, since a schema change will
not apply to an existing one:

```bash
docker compose rm -sfv generator && docker volume rm shinzohub-demo_generator-data
docker compose rm -sfv host      && docker volume rm shinzohub-demo_host-data
```

One limit worth knowing when only the generator is built from source: the host
uses the schema baked into its own image, so if the build under test renames
collections or adds fields, the generator will publish them and the host will
quietly ignore them — a healthy-looking stack with an empty host. Either build
the host from source too, or query the generator directly on `:9181` rather than
the host on `:9281`.

## Why the collections say "Mainnet"

Collection names are derived as `{CHAIN_NAME}__{CHAIN_NETWORK}__Block`, so the
data lands in `Ethereum__Mainnet__Block` even though it comes from anvil.

That is deliberate. The host resolves its schema from a registered indexer on
chain; with chain-only bootstrap there is none, so it falls back to the schema
baked into its image — and that image is the `ethereum-mainnet` build, whose
schema is named `Ethereum__Mainnet__*`. If the generator published under
`Ethereum__Local__*` the names would not line up and **nothing would replicate**,
while both services still looked perfectly healthy.

Only the naming says Mainnet; the chain is your local anvil.

## Notes on the images

Every component runs a published image. ShinzoHub gets a three-line layer on
top of its pinned image (`shinzohub/Dockerfile`) that installs `jq`, which
genesis construction needs and the `debian-slim` base does not ship. The hub
binary itself is never rebuilt from source.

`shinzohub/entrypoint.sh` replaces the image's own entrypoint, which in
standalone mode builds a generic genesis with no `acc0`/`hermes` keys, no admin
parameter and no ICA controller — none of which this demo can run without.

## Host event filtering is off

`host/config.yaml` sets `event_filter.enabled: false`, deliberately. The filter
is a live DefraDB `ReplicationFilter`: when enabled it rejects every
transaction, log and access-list entry that does not match one of its groups,
while still letting blocks and signatures through. Its default groups are
Uniswap V3 / USDT / USDC mainnet addresses, none of which exist on anvil — so
leaving it on produces a stack that looks healthy while storing nothing but
empty block headers.

## Ethereum data

`seeder/seed.sh` deploys a 39-byte contract that emits a `Transfer`-topic log on
any call, then alternates calls to it with plain value transfers. The contract
is raw bytecode because the foundry image ships no `solc`. Without the seeder,
anvil produces only empty headers and the transaction, log and receipt paths
never get exercised.
