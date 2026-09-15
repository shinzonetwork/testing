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
file once `create connection` succeeds; `register-ica` polls for the ICA channel
to reach `STATE_OPEN` inside its own container and exits only then, so
downstream services gate on `service_completed_successfully` rather than a sleep.

## Configuration

Everything lives in `.env`. The values worth knowing about:

- **`SHINZOHUB_SHA`** — ShinzoHub publishes only commit-SHA tags, from pushes to
  `main` and `develop`. The default is the `origin/develop` tip.
  `scripts/demo` does not exist on `main`, so `develop` is the branch that
  carries this demo.
- **`SHINZOHUB_CHAIN_ID=91273001`** — not the `91273002` the upstream demo
  scripts use. `Feat/change chain (#95)` moved `ChainID18Decimals` to the
  testnet value, and the pinned SHA is after that commit. If you repin to an
  older SHA, set this back to `91273002`; it is referenced in exactly one place
  and flows to the hub, the Hermes config and the ICA scripts from there.
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

The `docker-compose.yml` files in the generator and host repos both reference
tags that are not useful here: the generator's `:standard` is unpublished
entirely, and the host's `:v0.6.5-ethereum-mainnet` resolves but dates from
July. This stack pins both to `v0.6.5.4-ethereum-mainnet`, which exists in both
repos and was built from the same release (the two images are three minutes
apart).

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

Four of the six components run published images unmodified. ShinzoHub gets a
three-line layer on top of its pinned image (`shinzohub/Dockerfile`) that
installs `jq` — genesis construction needs it and the `debian-slim` base does
not ship it. The hub binary itself is never rebuilt from source.

`shinzohub/entrypoint.sh` replaces the image's own entrypoint. The upstream
`STANDALONE=1` path builds a generic genesis with no `acc0`/`hermes` keys, no
admin parameter and no ICA controller, so it cannot drive this demo.

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
any call, then alternates calls to it with plain value transfers. The foundry
image has no `solc`, so the contract is raw bytecode rather than a forge
project. Without the seeder, anvil produces only empty headers and the
transaction, log and receipt paths never get exercised.
