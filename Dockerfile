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

# Copy pre-built binary (built by GitHub Actions)
COPY masc-mcp-linux-x64 /app/masc-mcp
RUN chmod +x /app/masc-mcp

# Create non-root user for runtime
RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser

# Create data directory for JSONL fallback
RUN mkdir -p /app/.masc && chown -R appuser:appgroup /app/.masc

# Cascade config (GLM-only for Railway, no local llama-server)
COPY config/cascade.json /app/config/cascade.json

ENV PORT=8080
ENV MASC_BASE_PATH=/app
ENV MASC_CONFIG_DIR=/app/config

EXPOSE 8080

USER appuser

CMD ["/app/masc-mcp", "--port", "8080", "--base-path", "/app"]
