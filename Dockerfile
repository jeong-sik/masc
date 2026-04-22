# MASC MCP Server - Production Dockerfile
# Runtime image for the CI-built Linux Eio binary.
# NOTE: Dashboard SPA (assets/dashboard/) is not included.
# To add it, use a multi-stage build with Node.js or COPY from CI artifact.

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

# Create data directory for JSONL fallback
RUN mkdir -p /app/.masc && chown -R appuser:appgroup /app/.masc

# Copy all config files. CI may generate additional JSON alongside tracked files.
COPY config/ /app/config/

ENV PORT=8080
ENV MASC_BASE_PATH=/app
ENV MASC_CONFIG_DIR=/app/config

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -fsS http://localhost:${PORT}/health || exit 1

USER appuser

# --base-path is already set via MASC_BASE_PATH; avoid duplication.
CMD ["/app/masc-mcp", "--port", "8080"]
