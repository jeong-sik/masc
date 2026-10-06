# Machine activity known-refusal review response

Independent source review of the integrated #41203 tree found that a canonical `RuntimeTomlSaveRejected` was routed into the generic unknown-write catch after POST dispatch. That incorrectly marked a known pre-replacement refusal uncertain, announced a possible write, reread the file, and kept Save blocked until explicit reapply/discard.

The bounded repair handles that existing typed error separately under the existing request/authority ownership fence. It keeps draft, current file, last observation and save revision, reports the known refusal, and allows explicit retry. Unknown transport outcomes and unconfirmed receipts retain their existing uncertainty and readback behavior. No Browser/Exact producer was edited and no model-resume call was added.

The new actual session regression receives the canonical error after the mocked API's real beforeDispatch callback. It failed on the original implementation (handle 30607, exit 1, uncertain=true). It asserts unchanged draft/current/observation, no shared source-generation increment, no extra file/inventory read or consumer refresh, then explicit successful retry using the original revision. Canonical HTTP400 classification already has separate API coverage in the parent; this test exercises its newly added consumer.

Final integrated execution (handle 40755, exit 0): 264 tests across five suites passed, followed by dashboard TypeScript and scoped ESLint. Scope: machine parser, Machine panel/session, Lane inventory, Settings and raw TOML editor. The previous 263-test integration and original Chromium evidence remain historical, not final response proof. Raw RED/GREEN/type/lint logs are copied unchanged with source hashes in checks.json. No browser, native, backend/emulator, full CI, deployment or release execution is claimed.

Commands from repository root:

```sh
pnpm --dir dashboard test src/components/machine-lane-activity-panel.test.ts -t 'retains a known no-write raw refusal'
pnpm --dir dashboard test src/lib/machine-lane-activity.test.ts src/components/machine-lane-activity-panel.test.ts src/components/lane-inventory-panel.test.ts src/components/settings-surface.test.ts src/components/runtime-toml-editor.test.ts
pnpm --dir dashboard exec tsc --noEmit --pretty false
pnpm --dir dashboard exec eslint src/lib/machine-lane-activity.ts src/lib/machine-lane-activity.test.ts src/lib/machine-lane-activity-session.ts src/lib/machine-lane-observation.ts src/components/machine-lane-activity-panel.ts src/components/machine-lane-activity-panel.test.ts src/components/lane-inventory-panel.ts src/components/lane-inventory-panel.test.ts
```
