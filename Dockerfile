# MASC MCP Server - Production Dockerfile
# Two stages:
#   1. dashboard-builder: Vite SPA build (Node 22).  Produces /build/assets/dashboard.
#   2. runtime: Ubuntu 24.04 with the OCaml binary + the SPA copied in.

# ---- Stage 1: dashboard SPA -------------------------------------------------
FROM node:22-slim AS dashboard-builder

# corepack ships with Node 22 but is opt-in.  Pin pnpm to the version
# package.json declares (10.31.0) so build-time pnpm matches dev/CI.
RUN corepack enable && corepack prepare pnpm@10.31.0 --activate

WORKDIR /build/dashboard

# Copy lockfile + manifest first so `pnpm install` cache layer survives
# unrelated source edits.
COPY dashboard/package.json dashboard/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile --prefer-offline

# Copy the rest of the dashboard sources (env files, src, vite.config, etc.).
# .dockerignore must whitelist dashboard/.env.production for `vite build`
# (mode=production) to pick up VITE_DASHBOARD_WS_ONLY=true.
COPY dashboard/ ./

# vite.config.ts sets outDir='../assets/dashboard' → output lands at
# /build/assets/dashboard relative to the Vite working directory.
RUN pnpm run build

# ---- Stage 2: runtime -------------------------------------------------------
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    libffi8 \
    libgmp10 \
    jq \
    libpq5 \
    libsqlite3-0 \
    libssl3t64 \
    libzstd1 \
    tini \
    zlib1g \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# The deployment context supplies both release executables. The runtime never
# starts directly: the entrypoint validates the mounted BasePath under the
# canonical writer lease and then exec-hands that lease to this binary.
ARG BINARY_PATH=masc-linux-x64
COPY ${BINARY_PATH} /app/masc
COPY masc-deployment-preflight-helper \
  /app/masc-deployment-preflight-helper
COPY scripts/check-runtime-deployment-preflight.sh \
  /app/masc-check-runtime-deployment-preflight
COPY scripts/container-runtime-entrypoint.sh /app/masc-runtime-entrypoint
RUN chmod +x \
  /app/masc \
  /app/masc-deployment-preflight-helper \
  /app/masc-check-runtime-deployment-preflight \
  /app/masc-runtime-entrypoint

# Create non-root user for runtime
RUN groupadd --system appgroup && useradd --system --gid appgroup appuser

# Runtime state lives under MASC_BASE_PATH=/app. Identity/config state resolves
# under /app/.masc, while RFC-0121 bulk tool data resolves to sibling /app/data.
# Both must be writable by the non-root runtime user.
RUN mkdir -p /app/.masc /app/data \
    && chown -R appuser:appgroup /app/.masc /app/data

# Copy all config files. CI may generate additional JSON alongside tracked files.
# MASC_CONFIG_DIR points here, so this is the image-baked config root, not
# the mutable runtime storage root.
COPY config/ /app/config/

# Copy the built dashboard SPA from the build stage.  lib/web_dashboard.ml
# resolves the index at $MASC_BASE_PATH/assets/dashboard/index.html, which
# is /app/assets/dashboard/index.html under the env settings below.
COPY --from=dashboard-builder /build/assets/dashboard /app/assets/dashboard
RUN chown -R appuser:appgroup /app/assets

ENV PORT=8080
ENV MASC_BASE_PATH=/app
ENV MASC_CONFIG_DIR=/app/config
ENV MASC_BASE_PATH_LEASE_DIR=/app/.masc/runtime/base-path-lease
ENV OCAML_RUNTIME_EVENTS_DIR=/app/.masc/runtime/events

VOLUME ["/app/.masc", "/app/data"]

EXPOSE 8080

# Graceful shutdown: bin/main_eio.ml runs a 4-phase shutdown
# (NOTIFY → HOOKS → BOARD → CANCEL) on SIGTERM. Make the contract
# explicit so docker stop / compose / k8s never replace it with SIGKILL
# without going through the OCaml shutdown path first.
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -fsS http://localhost:${PORT}/health || exit 1

USER appuser

# tini is PID 1, masc runs as PID 2. tini forwards SIGTERM to its
# child (preserving STOPSIGNAL contract) and reaps zombies. Compose's
# `init: true` would do the same via docker-init, but baking tini in
# guarantees zombie reaping for plain `docker run` without --init too.
ENTRYPOINT ["/usr/bin/tini", "--", "/app/masc-runtime-entrypoint"]

# --base-path is already set via MASC_BASE_PATH; avoid duplication.
CMD ["/app/masc"]
