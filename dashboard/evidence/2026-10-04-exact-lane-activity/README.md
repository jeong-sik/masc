# Exact activity readout

From `dashboard`, run:

```sh
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:1 node evidence/2026-10-04-exact-lane-activity/browser-fixture.mjs
```

The harness owns a Vite server on a free port and Chromium. Actual Status,
LaneInventoryPanel, transport and decoders read synthetic `/api/v1/lanes`
responses: off with one accepted run, off after that run finishes, then on with
the same HTTP/CLI declaration order. The only UI action is Refresh Lanes;
there is no toggle/save action in this fixture or change.

Five checks pass with no writes, page errors or unexpected API routes. Both
screenshots show the selected Librarian detail and retained candidate order.
They do not prove real backend publication, native TUI or completion of a model
run. See the [full check record](../../../docs/evidence/2026-10-04-exact-lane-activity/).

The 38 tests in `tests.txt` exercise the standalone decoder, inventory decoder,
inventory component and Internal Agents monitor. TypeScript and changed-file
lint logs are included. Source/harness hashes are in the full check record.
