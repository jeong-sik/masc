# Operator refresh completions retain their admitted owner

Parent: `804b90958ac00ebeb9e7655c5d3134794bf6b3c7` (#42439).

Four actual snapshot/digest success/failure fixtures reproduced old-account completions changing a replacement account's loading/data/error state. The old finally cleared loading even when the replacement account owned the visible state (`/tmp/operator-refresh-auth-red-20261012.log`). Only HTTP transport is mocked; credential revisions, reactive state and refresh control flow are real.

Inflight and queued refreshes now carry immutable credential revision and completion-promise records. Admission publishes the operation before observable state changes, allowing synchronous observers to coalesce against its actual completion. Every publication boundary validates both credential revision and exact operation identity. Old completions cannot clear a replacement operation, publish data/errors or stamp its freshness. Freshness receipts also carry the credential revision.

A new-account refresh starts independently of the old account's inflight read. A forced followup keeps its original owner and does not start under a replacement account. Its final cleanup clears only its own followup record. Replacement/followup fixtures observe two actual reads, finish the old read and queued work, verify that the new read stays busy and coalesces correctly, then finish the new read and verify its result/cleanup. They release all deferred reads in finally.

Adversarial review found the digest followup cleanup mistakenly attached to the snapshot chain in candidate 67660. Two actual observer-failure fixtures also reproduced a loading-finally exception leaving the inflight operation retained, preventing the next fetch (`/tmp/operator-refresh-observer-cleanup-red-20261012.log`). Cleanup is now on the correct chain, and a nested finally releases the exact inflight record even when a loading observer throws. Both fixtures require the original and queued promises to reject, then prove a fresh fetch and its forced followup execute and finish. This replaces the earlier candidate's cleanup claim; no PASS on 67660 is claimed.

Focused validation completed: `npx vitest run src/operator-actions.test.ts` passed 49 tests (`/tmp/operator-refresh-auth-focused-20261012.log`), and `npx tsc --noEmit` exited 0. Existing current-owner freshness, concurrent coalescing, forced reads, action receipt publication and initial admission fixtures remain in this scope.

This covers refresh admission/coalescing/publication ownership. It does not cancel old HTTP bodies, clear already-visible account data on credential replacement, partition pending/log state or certify downstream UI effects. Those remain separate work. No CI, installation, live provider/server, screenshot, TUI runtime or formal approval is claimed. The full chat goal remains active.
