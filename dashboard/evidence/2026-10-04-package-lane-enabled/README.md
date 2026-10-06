# Package activity display

From `dashboard`, run:

```sh
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:1 node evidence/2026-10-04-package-lane-enabled/browser-fixture.mjs
```

The harness starts and closes its own Vite server on an ephemeral localhost port.
It renders the actual Lane Add-ons component and decoder with synthetic HTTP.
All API calls are intercepted; it performs no operator writes. The screenshots
show desired off with a still-failed worker and, after Refresh, configured off
with a retained detached worker and evidence. This is display proof only.

`initial-fixture-routing-failure.json` records a superseded harness failure: a
source-module URL was intercepted as an API call. The successful runner allows
non-API URLs through. See `browser-result.json` for the final observed result.
The mobile screenshot retains the existing horizontally scrolling table; mobile
layout redesign is outside this change.
