# Machine activity session outcomes review response

Three review findings on `dashboard/src/lib/machine-lane-activity-session.ts` (threads PRRT_kwDOQ7_DYc6o26Yc, PRRT_kwDOQ7_DYc6o26Yf, PRRT_kwDOQ7_DYc6o3Ezu) were confirmed by tracing the head `30edd73a134dd8d9731781ced50bd5c1c08d2bce`.

- A workspace switch during preview or the save token wait marked the save uncertain, because `invalidate()` read `phase === 'saving'`, which starts before the raw POST is dispatched.
- `read()` waited for the file and `/api/v1/lanes` through `Promise.allSettled`, so a slow inventory kept the editor in `reading` with `current` cleared until the 35 s GET timeout.
- A `RuntimeTomlSaveRejected` or `RuntimeTomlRevisionConflict` that arrived after a workspace switch was ignored by the ownership check, while `invalidate()` had already marked the save uncertain.

Repair:

- A `SaveAttempt` record moves `checking -> sent -> answered`. Only a `sent` attempt becomes uncertain when ownership moves.
- `uncertain` now names the `SaveAttempt` that caused it. A late typed no-write clears only that attempt's uncertainty. The conflict document is not adopted, and `current` stays cleared, so a read is still required before the next save.
- The file read settles on its own and gates editing. The server observation is a typed union (`unknown | reading | observed | failed`). A late inventory response is applied only while its `reading` value is still the current one, so a later read, save or workspace switch discards it.

RED (`red.log`, exit 1): with the final test file and the original session and panel, 5 new regressions failed and the guard test passed. A (preview, token wait) and C (refusal, conflict) failed with `expected true to be null`. B failed with `expected 'reading' to be 'idle'`. The guard test, "lets a late refusal settle only the save that sent it", passes on both versions. It keeps the fix from clearing another attempt's uncertainty.

GREEN (`green.log`, exit 0): 169 tests across 4 files passed. The machine panel file passed 61 of 61. Lane inventory, exact and browser activity panel files also passed. `tsc.log` exit 0, `eslint.log` exit 0 (only the zsh profile `compdef` line). No browser, backend, full CI or release execution is claimed.

Commands from `dashboard/`:

```sh
pnpm exec vitest run --config vitest.config.ts src/components/machine-lane-activity-panel.test.ts -t "settles a late raw refusal|settles a late revision conflict|lets a late refusal settle only|keeps an unsent save certain|settles an editable file read"
pnpm exec vitest run --config vitest.config.ts src/components/machine-lane-activity-panel.test.ts src/components/lane-inventory-panel.test.ts src/components/exact-lane-activity-panel.test.ts src/components/browser-lane-activity-panel.test.ts
pnpm typecheck
pnpm exec eslint src/lib/machine-lane-activity-session.ts src/components/machine-lane-activity-panel.ts src/components/machine-lane-activity-panel.test.ts
```
