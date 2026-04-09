# Remote MCP Operator Guide

When binding the MASC MCP server to a non-loopback address (`0.0.0.0`),
treat the endpoint as remotely exposed and configure authentication.

## Auth Configuration

Set `MASC_AUTH_TOKEN` before starting the server:

```bash
export MASC_AUTH_TOKEN="$(openssl rand -hex 32)"
```

Clients include the token via the `Authorization: Bearer <token>` header
or the `?token=<token>` query parameter on the SSE stream URL.

## Transport Security

For production remote access, use a TLS-terminating reverse proxy
(e.g., Cloudflare Tunnel, nginx, Caddy) in front of the MCP server.
The server itself speaks plain HTTP.

See also: [docs/spec/09-server-transport.md](spec/09-server-transport.md).
