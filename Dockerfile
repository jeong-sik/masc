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
    libpq5 \
    libsqlite3-0 \
    libssl3t64 \
    libzstd1 \
    zlib1g \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Binary path configurable via build arg for local dev vs CI.
# Local:  dune build --release bin/main_eio.exe && \
#         docker build --build-arg BINARY_PATH=_build/default/bin/main_eio.exe .
ARG BINARY_PATH=masc-mcp-linux-x64
COPY ${BINARY_PATH} /app/masc-mcp
RUN chmod +x /app/masc-mcp

# Create non-root user for runtime
RUN groupadd --system appgroup && useradd --system --gid appgroup appuser

# Runtime state lives under MASC_BASE_PATH=/app, which resolves durable JSONL
# storage to /app/.masc. Keep it separate from the immutable config seed below.
RUN mkdir -p /app/.masc && chown -R appuser:appgroup /app/.masc

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

VOLUME ["/app/.masc"]

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -fsS http://localhost:${PORT}/health || exit 1

USER appuser

# --base-path is already set via MASC_BASE_PATH; avoid duplication.
CMD ["/app/masc-mcp", "--port", "8080"]
