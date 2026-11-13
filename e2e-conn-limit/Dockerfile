# E2E conn-limit images, built only from local sources.
#
# The build context is assembled by run.sh in .build/:
#   client/     shinzo-indexer-client working tree (uncommitted changes included)
#   defradb/    git archive of DEFRADB_REF from the local defradb checkout
#   probe/      the connection probe in this directory
#   target.yaml generator config for the target
#
#   docker build --target generator -t shinzo-indexer:connlimit .build
#   docker build --target probe     -t shinzo-connprobe:connlimit .build

# ── generator: the target node ───────────────────────────────────────────────
FROM golang:1.27.3-bookworm AS generator-build
WORKDIR /src
COPY defradb ./defradb
COPY client ./client
WORKDIR /src/client
# Build against the local defradb tree instead of the version pinned in go.mod.
RUN go mod edit -replace github.com/sourcenetwork/defradb=../defradb && go mod tidy
# CGO stays on: lens/host-go's wasmtime runtime is cgo-only (see the client Dockerfile).
RUN CGO_ENABLED=1 go build -ldflags="-w -s" -o /out/block_poster ./cmd/block_poster

FROM debian:bookworm-slim AS generator
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=generator-build /out/block_poster /app/block_poster
COPY target.yaml /app/config/config.yaml
RUN mkdir -p /app/.defra /app/keys /app/logs && touch /app/logs/logfile
EXPOSE 8080 9171
CMD ["./block_poster", "-config", "config/config.yaml"]

# ── probe: opens libp2p connections until the target refuses them ────────────
FROM golang:1.27.3-bookworm AS probe-build
WORKDIR /probe
COPY probe/ ./
RUN CGO_ENABLED=0 go build -o /out/connprobe .

FROM debian:bookworm-slim AS probe
COPY --from=probe-build /out/connprobe /usr/local/bin/connprobe
ENTRYPOINT ["connprobe"]
