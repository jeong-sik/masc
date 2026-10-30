# Pending Keeper chat reconstruction, 2026-10-25

Relates #26364. Code tested/reviewed: `964821db14abd6aee6104919dc0ef029d9c76d12`, base `d98835aec86ae8c302b4cc43474c249ef1425d29`.

The server lists ascending queued operations with an exclusive int64 cursor and a 100-row page limit. The panel previously read one page and required Admin even though server queue mutation and turn interrupt use broadcast authority. The client now follows pages through empty, uses exact BigInt cursors, rejects nonadvancing pages or later failures without publishing a partial list, and replaces repeated moved IDs at their latest observed position. Worker opens the panel; Reader remains blocked. The server still authorizes mutations.

## Actual validation

- Four new pagination cases failed against the unmodified client (valid operation envelopes), then passed with the fix.
- `cd dashboard && ./node_modules/.bin/vitest run --config vitest.config.ts src/api/keeper.test.ts src/components/keeper-shared.test.ts --no-file-parallelism --maxWorkers=1 -t 'listQueuedKeeperChatOperations|operation|each text around media'`: **14 passed**, 71 outside-selection skipped. Includes Worker/Admin edit dispatch, Reader denial and existing multimodal control behavior.
- Earlier full execution of those two files: **83 passed, 1 failed** (before adding the Worker parameterized case). The unrelated live tool-output hydration case expected `hydration-failed`, received `pending`. That exact case also failed on unchanged main d98835a. Raw log hashes and actual excerpts are in validation-results.json. This is not a full-suite PASS.
- Actual Ego Chromium task49 rendered the candidate KeeperConversationPanel and client with Worker summary. Controlled HTTP fixture files contain 100 rows, then row101, then empty. After full reload the panel performed cursor requests100/101, rendered101 rows, and enabled edit/cancel on request101. Browser-result.json and the visually inspected screenshot preserve the observation. Fixture auth summary and data are controlled inputs, not production auth/backend proof.
- Browser task49 finished with keep:none. Vite fixture entrypoints are temporary; archived fixture sources show the wrapper used. Each row uses the strict operation/input v1 envelopes, ID `kmsg-proof-N`, sequence N, text `Pending request N`, created_at1792900000; null instructions/context and no attachments. Rows1..100 are start.json, row101 is100.json, empty is101.json.

## Remaining boundary

Pages are live reads, not a coherent snapshot: consumption/editing during traversal can make an earlier row stale until refresh. No backend/storage code changed. Submitter identity/ownership policy, real server restart/edit persistence, new-device production auth, installed runtime and full regression are unverified. #26364 remains open. No local OCaml build or CI was requested for this TypeScript repair. The complete feature/test source hashes are recorded separately so later evidence-only commits do not relabel execution.
