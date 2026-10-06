# PR41161 integration with repaired Runtime draft sessions

Original head `6e9b992f7cbbe497ceb098ebd9eea9a537af346c` now really merges
published parent `20cc51141851e3c3da45e9d9905a46cbe0ae8a45` (#41160).
Production changes remain the originally reviewed workspace-bound shared
catalog/resolved resources and Fleet error presentation. The merge was clean;
two new parent Overview tests needed their mutable fixture assignments renamed
to this PR's existing test-owned `catalogMock`. Parent production, mandatory CAS,
Runtime draft races, clean-read retry and mounted Settings notification remain.

## Current execution

- Fourteen focused suites: 440 passed, including the twelve resource/consumer
  suites and both parent Runtime editor/Settings interaction suites.
- Whole dashboard TypeScript: passed. All own changed TS files passed ESLint;
  the corrected Overview fixture then passed scoped ESLint again.
- Actual Chromium fixture: eight assertions passed, zero mutation requests and
  page errors. Actual AgentRuntimeStrip and FleetRotationSection remain mounted
  through authority changes, stale callbacks, failures, explicit recovery and
  withdrawal. HTTP is synthetic; API parsing and styled components are actual.
  Regenerated browser result and screenshots matched the preserved original
  output bytes. `browser-result.json` is copied here with the new execution log;
  historical evidence was restored byte-for-byte after the run.

Initial integrated tests had three ReferenceErrors from the two stale fixture
names (437 passed), and TypeScript reported those names. The references were
corrected without changing test assertions or product behavior before the final
440-case execution. Original failure logs remain in `/tmp/pr41161-tests.log`
and `/tmp/pr41161-tsc.log` in the author workspace.

From dashboard:

```sh
pnpm test src/lib/runtime-workspace-resource.test.ts src/lib/runtime-catalog-resource.test.ts src/lib/runtime-config-refresh.test.ts src/components/keeper-runtime-model-editor.test.ts src/components/keeper-config-panel.test.ts src/components/keeper-detail-runtime.test.ts src/components/keeper-workspace/keeper-workspace-rail.test.ts src/components/tools/config-resolution-panel.test.ts src/components/fleet-aside-extras.test.ts src/components/overview/runtime-stats.test.ts src/components/runtime-environment-editor.test.ts src/components/agent-monitor/runtime-strip.test.ts src/components/runtime-toml-editor.test.ts src/components/settings-surface.test.ts
pnpm exec tsc --noEmit --pretty false
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:1 node evidence/2026-10-04-runtime-workspace-cache/browser-fixture.mjs
```

Logs retain exact raw output bytes, including EOF blank-line warnings. No native
build, backend/CLI/model execution, full suite, Full RC or deployment is claimed.
Independent Overview metrics/usage and Config probe observation lifetimes are
separate descendant #41182 work, not added to this shared-cache patch.
