# First conversation page before aggregate enrichment

## Reproduced behavior

The installed Dashboard on runtime `2f3c5aa58048266e257ef01eb0759b344629debc`
was verified as admin and requested code-reviewer `/chat/history`. Browser
Resource Timing recorded HTTP 504 after 34,039.9ms. Initial conversation display
waited for this combined direct/autonomous/trace read.

The source preview uses the existing canonical `/chat/history/page` concurrently
with aggregate enrichment. A nonempty page publishes `partial` history; only the
aggregate settles full hydration. Empty direct history does not establish absence
of autonomous conversation. A failed optional page leaves aggregate processing
intact; an aggregate failure retains page rows and releases the initial-read guard
for retry. Request ownership rejects obsolete results. The page does not change
the user's older-page cursor. Exact-id aggregate rows enrich preview rows; preview
appends absent from the aggregate's earlier observation are retained. Tool output
hydration starts when rows first become available and runs once per request.

## Validation

- 96 tests passed in `keeper-actions.test.ts` and
  `keeper-shared-hydration.integration.test.ts` (5.91s). New cases cover partial
  publication, local/older/autonomous rows, stream metadata, aggregate failure and
  retry, empty direct history, failed preview, stale completions and newer appends.
- Dashboard `tsc --noEmit`, ESLint on the four changed TS files and
  `git diff --check` passed. No local Dune or CI was run.
- A Vite source preview at 127.0.0.1:5174 used the existing live server as backend.
  On a cold application reload with code-reviewer selected, a MutationObserver
  recorded the first canonical history row at 1,086.6ms from navigation. At
  1,166.5ms, 37 canonical rows were visible, the loading card was absent, and the
  page request had completed in 157.5ms (HTTP 200; 129,077 encoded bytes).
  The aggregate request had not completed at that observation.

`browser-preview.json` retains these observations. The screenshot is local at
`/tmp/masc-opt-chat-browser-preview.png`; it contains private runtime conversation
and is not published. This single source-preview observation is not a controlled
before/after latency trial, an installed Dashboard verdict or proof that aggregate
work became faster. Vite startup/module loading is included in the navigation
measurement. Physical display latency is not measured.

## Runtime cycle and remaining work

Both previously merged continuity optimizations are ancestors of the live runtime.
The original installed server (546e5a2) was gracefully stopped after read-only
configuration and 20 durable-store scans accepted the candidate's data. A frozen
44f8282 candidate passed the full gate and started; an external SIGTERM and a
replacement process then installed runtime 2f3c5aa. Measurements retain those
separate instances; this source preview does not replace that server.

Early post-startup API sampling retained timeouts and 404 next-request responses
before Keeper bootstrap. After the fleet resumed (20 fibers vs 17 before restart),
all 75 repeated responses were valid. Next-request median/max were 524.82/1157.53ms
vs 654.06/2455.96ms before; history-page median was 96.80ms vs 17.42ms, roster
380.69ms vs 57.94ms and MCP ping 172.76ms vs 5.90ms. Fleet/data load and process
warmth differ, so these establish no fleet-wide performance improvement and do
not attribute a change to either individual patch. Raw packets and the deployment
receipt remain in local reports. The reproduced aggregate 504 remains a separate
backend concern tracked with #44249.
