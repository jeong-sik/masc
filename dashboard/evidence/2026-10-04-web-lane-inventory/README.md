# Common Lane inventory display

Run from `dashboard`:

```sh
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:1 node evidence/2026-10-04-web-lane-inventory/browser-fixture.mjs
```

The script owns an ephemeral localhost Vite server and closes it and Chromium.
It renders the actual Status route/menu, inventory component and decoder against
synthetic HTTP. The baseline wire fixture is copied from the TUI fixture retained
under `docs/evidence/2026-10-04-tui-lane-inventory/fixture-wire-inputs.json`.
This shares a producer contract with the existing consumer check; it is not a new
live backend response. A synthetic disabled declaration and failed retained
worker exercise off-intent display without claiming cleanup.

The desktop screenshot includes all 12 built-in kinds and the added package.
The mobile screenshot shows search, selected detail and a stale-read notice after
a synthetic 503. The harness checks focus, no horizontal page overflow and zero
writes/unexpected API routes/page errors. It does not execute a native backend,
TUI, worker, configuration save or deployment. Owner-screen links do not promise
selection of the same row in the destination screen.

Two independent source-review findings were addressed: null workspace authority
must not admit rows across connection changes, and inconsistent exact/configured
or package-ownership data must be rejected. Tests exercise those boundaries.
See `checks.json` and saved text output for checked source hashes and results.
