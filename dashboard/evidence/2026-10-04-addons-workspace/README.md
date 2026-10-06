# Add-ons workspace isolation

Finding B6: after switching from workspace A to B, the Add-ons panel retained A's
worker controls when B's read failed and retained frozen A Slice observations
even after B loaded. Two regression tests failed before the fix; see
`tests-before.txt`. The final focused tests include authority withdrawal, late
mutation receipts, pending actions in both workspaces, returning to the original
request ID, and a cancelled status read racing its replacement.

Run the browser check from `dashboard`:

```sh
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:1 node evidence/2026-10-04-addons-workspace/browser-fixture.mjs
```

The script starts and closes its own localhost Vite server and Chromium. It uses
the real Status route, Add-ons components, API transport and decoders with
synthetic HTTP and accepted execution workspace snapshots. There are four
explicit synthetic mutations: an observation and an action in each workspace.
No real backend, package worker, native TUI, deployment or merge is exercised.

The action request journal is local to the mounted Add-ons component. Its
workspace-switch retention does not cover screen unmount or page reload.
TOML draft sessions keep their existing separate retention contract.

The initial browser attempt used an exact label query that did not match the
select's browser accessible name, which also includes option text. That fixture
failure is saved separately. The corrected harness selects the combobox by role.
See `checks.json` for measured results and checked source hashes.


## Parent integration validation (2026-10-04)

Integrated published parent `1270dc3d2de2705db4388705d4c130ea0a0100f4`
(#41145) without conflicts. The workspace-isolation implementation remains
byte-identical to original head `23dad1927b8de74259dc3389f390ef1643319219`;
the component tests also retain the parent's unsafe-integer reading regression.
The Add-ons panel, workspace-isolation, and declaration-editor suites passed
58 tests. `tsc --noEmit --pretty false` and scoped ESLint passed. No new browser,
native backend/TUI, CI, deployment, or production execution is claimed.
The screenshots and browser logs above remain historical synthetic evidence.
