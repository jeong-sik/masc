# Candle Grade scope survey

The isolated survey completed400 planned calls across20 synthetic Goal inputs,20 repetitions each. All400 returned typed-valid Grade decisions. This measures distributions and repeatability; no human reference grades were supplied and no acceptance threshold is adopted here.

The CI executable embeds source `4fae8f4e3fef99a0b23871dd6bfc58a0250df43f` (SHA256 `fd5d67fd9befb6349f20521f1ea86759498d3d83187bbb2812808403df495a19`). The retained candidate Grade prompt has SHA256 `ea0085dc4b0de14f1cd3a61e9edb9ec216c973bb23ca8eb6d9866736c9482a85`. Every dispatch used the one declared `glm-coding.glm-5.3-flash` slot; no fallback, replacement trial or retrospective retry occurred. EIO_BACKEND was posix. The prior240-call measurements were not overwritten.

`exit.json` records exit0 at2026-09-29T18:46:22Z. The provenance auditor independently re-read all400 receipts and their800 durable registry events/payloads. It verified fixed actual inputs, identical rendered prompts per case, one dispatch per run,400 unique run IDs, available input/output payloads and matching registered/completed records. Assistant proposed grades and human labels were not model inputs. No live Goal, Task, ledger or Paid state was written.

The original `human-reference-*` IDs name assistant-created synthetic cases. They do not make this a human gold corpus. The human-grades sheet was blank during this measurement; the subsequently supplied case 19 operator anchor is recorded separately in docs/testing/candle-appraiser-calibration-proposal. Case04 repeats the CSV example used in the earlier experiment; this is not a fully unseen validation set.

| Case | Frozen Goal title | Observed distribution |
|---|---|---|
| 01 | Correct the misspelled label on the Preferences tab | trivial 20/20 |
| 02 | Show the accepted YYYY-MM-DD format and one example in the error returned for an invalid Goal due date | trivial 20/20 |
| 03 | Preserve the stored Goal due date when an edit changes only its priority | trivial 13/20, small 7/20 |
| 04 | Add CSV export for the filtered expense report | small 20/20 |
| 05 | Remember the most recently selected workspace tab and restore it after restarting the application | small 20/20 |
| 06 | Let a user search and select a Task using only the keyboard in the existing Goal editor | small 20/20 |
| 07 | Make same-name credential renewal and expired game-controller recovery atomic across HTTP and MCP requests | small 15/20, medium 5/20 |
| 08 | Reject unknown fields in a stored Goal and show the resulting unavailable state consistently in the server, dashboard and TUI | small 9/20, medium 11/20 |
| 09 | Expose a Keeper tool that reads its own current Candle balance and purchased items from the existing ledger | small 20/20 |
| 10 | Provide a portrait item catalog with previews for every listed item and restore the default appearance when the preview is cleared | medium 19/20, small 1/20 |
| 11 | Add profile image upload with file validation, stored resized images, authenticated retrieval and an account-settings preview | medium 20/20 |
| 12 | Show each Goal verification request and result in a timeline with its actual actor and evidence in both the dashboard and TUI | small 20/20 |
| 13 | Deliver a scheduled daily workspace report with persisted schedules, a durable delivery outbox, retry after restart and operator controls | medium 18/20, small 2/20 |
| 14 | Implement an append-only account ledger with atomic purchases, balances, item ownership, replay after restart and an audit view | medium 20/20 |
| 15 | Deliver the complete Candle purchase-and-equip workflow through Keeper tools, authenticated APIs, dashboard and TUI portraits | medium 20/20 |
| 16 | Allow two workspace instances to exchange Board posts, comments and reactions with authenticated peers, durable reconciliation and duplicate suppression | medium 19/20, small 1/20 |
| 17 | Provide HTTP and CLI model failover across Keeper turns with durable request receipts, operator-editable slot order and consistent server, dashboard and TUI observation | medium 20/20 |
| 18 | Provide a shared browser document editor with concurrent editing, access controls, durable history, presence and recovery after disconnect | medium 19/20, large 1/20 |
| 19 | Build a transactional workspace data subsystem that stores Goals, Tasks, Board activity and Keeper state in PostgreSQL with consistent backups, restore and operational metrics | epic 2/20, large 6/20, medium 12/20 |
| 20 | Build a hosted collaboration product with workspace creation, member access, shared Goals and Tasks, Board discussion, autonomous Keeper work, scheduled jobs and operator observability | epic 19/20, large 1/20 |

Four cases show visibly divided judgments:03(trivial/small),07(small/medium),08(small/medium),19(medium/large/epic). Cases14–18 predominantly return medium even where the assistant rubric proposed larger grades. That disagreement does not establish an incorrect model answer: the rubric is a proposal, not independently supplied human labels. No case has Large as its modal answer in this corpus. These results justify reviewing the definition of outcomes and subsystem scope before accepting all five grade boundaries.

The raw result and registry files are compressed without removing any row. The payload archive retains every original hash-addressed file. `SHA256SUMS` covers the bundle. To rerun the structural audit, extract the payload archive, decompress the two JSONL files, reconstruct the frozen workspace from plan/cases/runtime/prompts, and run `audit-provenance.py WORKSPACE EVIDENCE`. No model call is needed to verify this evidence.

The auditor verifies retained prompt bytes and their effective use, but does not certify a source commit for those bytes. `prompt_commit` in the historical freeze records is an unverified declaration; agreement between those declarations is not a commit-to-blob proof. The audit report explicitly marks that source attribution unverified.
