# Web approval admission ownership

Base: `6faf47887e52f75afe6836a29a2fc6a8ed35634b`.

Web approval rows now preserve the canonical server admission ID from both stream requests and the actual pending-inventory decoder. Inventory requires UUIDv7 IDs via the existing shared decoder. Stream termination can retire a known row only when its admission ID matches, and the existing expected-row publication guard protects that exact row. Required producer policy reason no longer has an invented empty fallback.

Functional reproduction: two distinct admission IDs use the same provider call ID, followed by the first admission's displaced event. With the former provider-keyed settlement restored temporarily, the real stream consumer incorrectly settled the second admission: one selected test failed in `/tmp/chat-web-approval-settlement-red.log`. The corrected source was restored before further edits/checks. The test also confirms that the matching second termination does settle the row.

Final checks: three suites, 162 tests passed using `pnpm exec vitest run src/keeper-stream.test.ts src/keeper-tool-approval.test.ts src/components/keeper-workspace/keeper-workspace-chat.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1`; log `/tmp/chat-web-approval-settlement-green.log`. `pnpm exec tsc --noEmit` exited successfully with no diagnostics, `/tmp/chat-web-approval-settlement-types.log`. `git diff --check` passed.

This is a staged consumer ownership repair. Storage remains indexed by provider call ID, hydration skips an existing provider-key row, and answer POST/backend settlement/late-memory still require the admission authority switch. Unknown settlements and terminal retention also require a durable frontier. No complete authority, full chat goal, CI, formal GitHub approval, merge, installed runtime or screenshot claim is made. Previous timeout arbitration received independent source PASS at its own exact head, not functional execution or formal approval.
