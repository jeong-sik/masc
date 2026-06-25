# MASC WebSocket Secure (WSS) Deployment Guide

The MASC server binary exposes a plain WebSocket endpoint at `/ws` (RFC 6455). It does **not** natively terminate TLS. To use `wss://` in production, run a TLS-terminating reverse proxy in front of MASC.

---

## What the server supports

| Feature | Supported |
|---|---|
| Plain WebSocket upgrade (`ws://`) | Yes, on `/ws` |
| Native TLS WebSocket (`wss://`) inside the binary | No |
| Secure WebSocket via reverse proxy | Yes (recommended) |

The `/ws` route is registered in `lib/server/server_routes_http_routes_frontend.ml` and handled by `Server_mcp_transport_ws.upgrade_connection`. The protocol after upgrade is MCP JSON-RPC over WebSocket.

---

## Agent card / discovery URL

`/.well-known/agent.json` and `/.well-known/agent-card.json` derive the WebSocket URL from the incoming request scheme. When the request arrives over `https`, the advertised URL is `wss://<host>/ws`. Make sure the proxy forwards the original scheme (see Caddy and nginx examples below).

---

## Caddy example

```caddy
masc.example.com {
    reverse_proxy localhost:8080 {
        header_up Host {host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Real-IP {remote}
    }
}
```

Caddy handles TLS automatically and forwards the `Upgrade` and `Connection` headers by default.

---

## nginx example

```nginx
server {
    listen 443 ssl http2;
    server_name masc.example.com;

    ssl_certificate     /etc/nginx/ssl/masc.example.com.crt;
    ssl_certificate_key /etc/nginx/ssl/masc.example.com.key;

    location / {
        proxy_pass http://localhost:8080;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
```

---

## Required forwarded headers

The proxy **must** forward these headers for WebSocket upgrade and discovery to work:

- `Host`
- `X-Forwarded-Proto` (so `agent-card.json` advertises `wss://`)
- `Upgrade`
- `Connection`
- `Sec-WebSocket-Key`
- `Sec-WebSocket-Version`
- `Sec-WebSocket-Protocol` (if present)
- `Sec-WebSocket-Extensions` (if present)

---

## Local / development

For local development the server binds to loopback and the dashboard connects with plain WebSocket:

```
ws://localhost:8080/ws
```

No proxy is required for local use.

---

## Cloudflare / CDN

If you put Cloudflare in front of MASC:

- Set the DNS record to **Proxied** (orange cloud).
- Use **Full (strict)** TLS mode between Cloudflare and the origin.
- Cloudflare terminates TLS and forwards the WebSocket upgrade to the origin.
- The origin still sees plain `ws://` on its side.

---

## Operational checklist

- [ ] Proxy forwards `Upgrade` and `Connection` headers.
- [ ] `X-Forwarded-Proto` is set to `https` for TLS requests.
- [ ] Proxy read/send timeouts are long enough for long-lived MCP sessions.
- [ ] `/ws` and `/.well-known/agent.json` return the expected `wss://` URL.
- [ ] Dashboard connects to the `wss://` URL when loaded over `https`.

---

## When native `wss://` might be needed

Native TLS inside the MASC binary is **not** in scope for this design. Add it only if:

- You cannot run a reverse proxy (e.g., embedded device).
- Your deployment requires end-to-end TLS without intermediate termination.

If you need native WSS, open a separate issue to add a TLS listener to `server_routes_http.ml` / `masc_grpc_server.ml`.
