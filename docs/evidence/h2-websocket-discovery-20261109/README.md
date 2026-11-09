# HTTPS dashboard discovery before the WebSocket connection

Source baseline: `66cb2c7317b2`. Observed on 2026-11-09.

The dashboard first calls `fetch('/ws')` in `discoverWsUrl`. Only a successful
discovery answer lets it construct `new WebSocket(wsUrl)`. A fresh HTTPS browser
session fetches over negotiated HTTP/2. The router refused every WebSocket route
without an upgrade capability, before the `/ws` handler could answer discovery.

Read-only probes of the running local listener showed:

```text
curl -ksS --http2 -D - https://127.0.0.1:8938/ws
HTTP/2 426
426 Upgrade Required: WebSocket upgrade unavailable on this transport

curl -ksS --http1.1 -D - https://127.0.0.1:8938/ws
HTTP/1.1 200 OK
ws_url = wss://127.0.0.1:8938/ws
```

These probes describe the then-running binary; its source identity was not
measured. The baseline source independently contains the same refusal path.
The cold-dashboard failure follows from that response and the client control
flow; no browser session or screenshot was captured.

`reproduce.py` extracts the production `Router.dispatch`, request-header checks
and frontend `websocket_handler` verbatim. It uses the installed `httpun`
request parser and stub response/auth/discovery/upgrade dependencies, so the
observed result is limited to routing and handler control flow:

```text
compiler=5.5.1
before: ordinary GET without capability 426; unsupported upgrade 426; capable upgrade 101
after:  ordinary GET without capability 200; unsupported upgrade 426; capable upgrade 101
```

Run `python3 docs/evidence/h2-websocket-discovery-20261109/reproduce.py` with
`ocamlfind` and `httpun` installed. Each run writes generated sources, binaries
and output under a fresh `artifacts/h2-websocket-discovery/<run>/` directory.

The production H2 gateway regression additionally asks the registered `/ws`
route using an HTTPS scheme/authority and checks the returned `wss://` URL; it
checks that the upgrade-only LSP endpoint still returns 426. That regression
was parsed locally, not run. No MASC Dune build, complete gateway test run, CI,
candidate TLS handshake, browser behavior or deployed fix is claimed.

This change enables ordinary HTTP discovery over HTTP/2. RFC 8441 WebSocket
over HTTP/2 remains outside RFC-0512's scope.
