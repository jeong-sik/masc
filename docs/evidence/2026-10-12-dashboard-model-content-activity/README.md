# Metadata-only model content activity

Base `13aac962b8ba3588ecad28a2a750b893a81e2fdb`.

Executed parent targeted test `-t 'metadata-only thinking and saying'`: exit1, one failed and134 skipped. A canonical Thinking activity with no exposed body left progress opening instead of thinking.

The live conversation now owns an immutable per-response inventory of exact generation/scope/block occurrences. Metadata can show Thinking or Saying without inventing hidden content. Closing the newest Text occurrence returns to an older still-open Thinking occurrence. Closing all observed pieces shows the response still in progress, without declaring response or turn completion. End notices cannot admit a new response. Ended occurrence tombstones prevent late start observations from reopening them. New response and runtime attempt boundaries retire the inventory. Late old/terminal events cannot claim current activity; historical observation-only frames do not create live progress.

Executed final verification from dashboard:

- `vitest run src/keeper-stream.test.ts src/keeper-chat-operations-local.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1`: exit0, 154 tests across2 files, final1.47s. New state scenario covers metadata-only channels, overlapping open pieces, partial/all close, end-before-observed tombstone, replay, newer generation and terminal late events.
- `tsc --noEmit`: final exit0. Initial typecheck caught duplicate display branch and unsupported findLast; both corrected before publication.
- `git diff --check`: exit0.

No local build, CI, real provider turn, installed application, browser or screenshot proof. The inventory is currently live entry state. Stored drafts recognize waiting but do not yet persist the occurrence inventory/tombstones; durable resume parity remains pending and is not certified by these tests.
