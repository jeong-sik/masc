# Persisted model-content occurrence ownership

Base `def949a4fd729e84ff2e7b7f535d55c57f8a680c`.

Executed parent hydration counterexample: targeted `keeper-actions.test.ts` selection `-t 'restores content closure tombstones'` exited1, one failed and119 skipped. Production operation storage/hydration dropped the ended occurrence inventory (received undefined).

The draft capture, stored-data normalization and operation hydration now preserve immutable model-content inventory. Stored payloads reuse the live SSE metadata validator and bind each occurrence to the stored admitted response floor. Unknown fields/channel, negative coordinates, duplicate occurrences and foreign generations invalidate response authority while preserving original conversation text.

Intermediate persistence counterexample: targeted local-operation test `-t 'preserves closed content'` exited1, one failed and24 skipped. A same-response incoming draft omitting inventory erased stored tombstones. Same-current-response merging now preserves missing observations and keeps closed records closed. Conflicting channels quarantine ownership; new current responses do not inherit old occurrence inventory. Existing journal cursor ordering remains authoritative.

Executed final checks from dashboard:

- Four focused suites `keeper-stream.test.ts`, `keeper-actions.test.ts`, `keeper-chat-operations-local.test.ts`, `schemas/sse.test.ts`, using `vitest run ... --config vitest.config.ts --no-file-parallelism --maxWorkers=1`: exit0, 487 tests across4 files, final2.86s.
- `tsc --noEmit`: final exit0.
- `git diff --check`: exit0.

The exercised flow includes real production stream-to-draft capture into test browser storage, storage re-read, actual operation hydration and late observed replay against restored tombstones. Synthetic frame data and mocked operation lookup exercise production state code; no installed application, actual browser screenshot, real provider turn, build or CI claim.

An initial working draft used a nonexistent validator identifier and failed with ReferenceError; corrected to the existing validateKeeperCustomPayload before the passing verification. No failed result is counted as PASS.
