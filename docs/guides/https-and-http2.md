# HTTPS and HTTP/2

The server has two HTTP listeners. Both serve the same route table
(RFC-0512): a route registered once answers on every transport.

| Default port | Transport | Protocols on the connection |
| --- | --- | --- |
| 8935 | cleartext | HTTP/1.1, or HTTP/2 prior knowledge (h2c) detected from the first bytes |
| 8938 | TLS 1.3 | HTTP/2 or HTTP/1.1, chosen by ALPN; a client without ALPN gets HTTP/1.1 |

Browsers speak HTTP/2 only over TLS with ALPN. A dashboard tab reaches
multiplexing (one connection for its SSE streams and requests, instead of
the six-connection HTTP/1.1 limit per origin) only through the TLS port.

## Configuration

| TOML key | Env name | Default | Meaning |
| --- | --- | --- | --- |
| `transport.https_port` | `MASC_HTTPS_PORT` | `8938` | HTTPS listener port. `0` turns the listener off. 8937 is the WebSocket listener's default, so it is not a candidate. |
| `transport.tls_cert_file` | `MASC_TLS_CERT_FILE` | none | PEM certificate chain, leaf first. |
| `transport.tls_key_file` | `MASC_TLS_KEY_FILE` | none | PEM private key of the leaf. |

Set both file keys or neither. One without the other refuses the boot with
`HTTPS listener: MASC_TLS_CERT_FILE=... is set but MASC_TLS_KEY_FILE is not`.
The environment wins over the TOML key, like every other transport key.

## Certificates

With no files configured the server uses a self-signed pair under
`<base-path>/.masc/tls/`: `server.crt` (mode 0644) and `server.key` (mode
0600). The key is P-256. The certificate names `localhost`, `127.0.0.1`,
`::1` and the bind host when that is one address, and is valid for 365
days. A boot generates the pair again when a file is missing or unreadable,
or when the certificate expires within 30 days. `/health` carries the
expiry under `https_listener.certificate.not_after` in the body it gives a
requester that may read the server's state: any request on a loopback server
without strict auth, a request with a verified credential on a server that
requires a token.

A browser warns about a self-signed certificate. For a local browser without
the warning, make a certificate the machine trusts with
[mkcert](https://github.com/FiloSottile/mkcert) and point the two keys at it:

```bash
mkcert -install
mkcert -cert-file ~/.masc-tls/localhost.pem -key-file ~/.masc-tls/localhost-key.pem localhost 127.0.0.1 ::1
```

```toml
[transport]
tls_cert_file = "/Users/you/.masc-tls/localhost.pem"
tls_key_file = "/Users/you/.masc-tls/localhost-key.pem"
```

## Cloudflare Tunnel

`cloudflared` speaks HTTP/2 to the origin only over HTTPS
([origin parameters](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/cloudflared-parameters/origin-parameters/)).
Point the ingress at the TLS port:

```yaml
ingress:
  - hostname: masc.example.com
    service: https://127.0.0.1:8938
    originRequest:
      http2Origin: true
      noTLSVerify: true
```

`noTLSVerify` accepts the self-signed certificate. With a configured
certificate signed by a CA the tunnel host trusts, use `caPool` instead.

## Checking a server

```bash
curl -k --http2 -sv https://127.0.0.1:8938/health 2>&1 | rg 'ALPN|HTTP/2 200'
curl -k --http1.1 -s -o /dev/null -w '%{http_version}\n' https://127.0.0.1:8938/health
openssl s_client -alpn h2 -connect 127.0.0.1:8938 </dev/null 2>/dev/null | rg 'ALPN'
```

The first prints `ALPN: server accepted h2` and `HTTP/2 200`, the second
prints `1.1`, the third prints `ALPN protocol: h2`.

The startup banner has a line `HTTPS :8938 → TLS 1.3, ALPN h2 + http/1.1
(self_signed certificate)`. The server log has `[tls <host>:<port>] HTTPS:
TLS 1.3, ALPN h2 and http/1.1` once the accept loop runs.

`/health` and `/api/v1/dashboard/transport-health` carry an `https_listener`
object. On `/health` it is in the body of a requester that may read the
server's state, not in the public probe a server that requires a token gives
a request without a credential:

| Field | Meaning |
| --- | --- |
| `status` | `off`, `not_started`, `bind_failed`, `listening`, `stopped`, `accept_error` |
| `port` | the configured port, or `null` when off |
| `certificate` | `{ "source": "configured" \| "self_signed", "not_after": "<RFC 3339>" }`, or `null` when off |
| `active_connections`, `accepted_total` | connections now open, connections accepted since boot |
| `alpn_h2_total`, `alpn_http1_total`, `alpn_none_total` | completed handshakes by ALPN result |
| `handshake_failures_total` | connections that ended before an application protocol was chosen: TLS alerts, protocol failures, cleartext sent to the TLS port, peers that left mid-handshake |
| `accept_errors_total`, `last_error` | accept failures and the last one's text |
| `last_accept_unix`, `last_accept_age_seconds` | the last accepted connection |

The OTel scrape has the same counts: `masc_https_accepts_total`,
`masc_https_alpn_total{protocol="h2"|"http/1.1"|"none"}`,
`masc_https_handshake_failures_total`, `masc_https_accept_errors_total`,
the gauge `masc_https_active_connections`, and the accept latency histogram
`masc_http_accept_latency_seconds{mode="tls"}`.

## When the port is taken

A bind failure does not stop the boot. The log has `[tls <host>:<port>]
bind failed, HTTPS stays off until the next boot: <reason>`,
`https_listener.status` is `bind_failed`, and the cleartext listener serves
as before. Two servers on one host need different `MASC_HTTPS_PORT` values,
or `0` on the second.

## What stays as it was

gRPC (8936) and the standalone WebSocket listener (8937) are cleartext. On
the TLS port a WebSocket upgrade works over an HTTP/1.1 connection. An ordinary
HTTP/2 `GET /ws` returns discovery JSON, so an HTTPS dashboard can discover its
`wss://` endpoint before opening the HTTP/1.1 WebSocket connection. An actual
upgrade without an upgrade-capable transport still answers 426; h2 has no
RFC 8441 extended CONNECT.

The dashboard decodes `transport-health` strictly: a bundle built before
this change rejects the `https_listener` field with a schema drift error on
the transport panel. Build the bundle from the same tree as the binary.
