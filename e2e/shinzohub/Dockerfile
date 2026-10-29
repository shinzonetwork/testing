# The published ShinzoHub image is debian-slim with nothing but the binary in it.
# Genesis construction needs jq, so this adds it on top of the pinned image.
# The hub binary itself is NOT rebuilt — it comes from the SHA-tagged image.
ARG SHINZOHUB_SHA
FROM ghcr.io/shinzonetwork/shinzohub:${SHINZOHUB_SHA}

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends jq \
    && rm -rf /var/lib/apt/lists/*
USER node

ENTRYPOINT ["/bin/bash"]
CMD ["/demo/entrypoint.sh"]
