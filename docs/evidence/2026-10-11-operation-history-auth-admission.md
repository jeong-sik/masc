# Operation history reconciliation authentication admission

The history reconciliation used by restored operations and failed sends read the durable REST transcript without checking whether the credentials changed while the read was pending. A late success could publish old-scope rows and delete the retained operation. A late rejection could overwrite a current-scope error. The failed-send caller also published its original stream error after a superseded reconciliation.

The reconciliation now captures the existing stored-token revision before acquisition and rejects stale success and failure before applying history or releasing local recovery. The failed-send caller gates its later action-error publication with the revision that admitted reconciliation, while still rejecting the original stream failure.

Direct deferred-response fixtures exercised both callers and both resolution outcomes. All four failed before their corresponding repair. Restored-operation fixtures also prove that a later current-auth read can replace the local observation and release its tracking record.

Validation: `pnpm exec vitest run src/keeper-actions.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1` passed 89 tests; `pnpm exec tsc --noEmit` and `git diff --check` passed. Independent source review found and confirmed repair of the second caller's missing publication guard.

These checks prove the history reconciliation boundary, not complete account isolation, operation-polling admission, live provider behavior, installation, CI, or actual browser screenshots. The full chat goal remains active.
