# MASC MCP Server - Production Dockerfile
# Uses pre-built binary from GitHub Actions (Ubuntu 24.04)

FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libpq5 \
    libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy pre-built binary (built by GitHub Actions)
COPY masc-mcp-linux-x64 /app/masc-mcp
RUN chmod +x /app/masc-mcp

# Create data directory for JSONL fallback
RUN mkdir -p /app/.masc

ENV PORT=8080
ENV MASC_BASE_PATH=/app

EXPOSE 8080

CMD ["/app/masc-mcp", "--http", "--port", "8080", "--base-path", "/app"]
