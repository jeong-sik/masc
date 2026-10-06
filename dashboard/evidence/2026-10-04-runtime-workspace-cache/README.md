# Shared runtime readings by workspace (B8)

Six cases reproduced loaded A data surviving B, late A success becoming B's
current reading, and authority withdrawal leaving the old data visible. The
saved pre-fix log records six failures. The final resource scenarios also cover
stable no-authority errors, no retries on render, recovery, stale errors/finally,
A-B-A, cancelled demand and resubscription. Real-resource consumer fixtures now
establish a confirmed workspace; readonly state mocks remain explicitly mutable
test-owned signals/objects.

Run the browser harness from `dashboard`:

```sh
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:1 node evidence/2026-10-04-runtime-workspace-cache/browser-fixture.mjs
```

The harness owns an ephemeral Vite server and Chromium. It renders the actual
AgentRuntimeStrip (requests during render) and FleetRotationSection (requests
once on mount), shared resource owners, transport and API decoders against
synthetic HTTP. Both components stay mounted across workspace changes. Identical
runtime/keeper IDs in A and B carry distinct capability and candidate readings.
Held A responses, B failures, explicit retry, lost authority and automatic
recovery are exercised without any mutation request. The screenshots show the
failed and recovered B readings; capability text is also asserted in the DOM.

No native backend, live Keeper, TUI, model invocation, merge or deployment was
tested. Overview's independent usage/metrics, ConfigResolutionPanel's probe and
Keeper config storage are not these two resources and are outside this proof.
See `checks.json` for commands, measured results and source hashes.
