# Exact Keeper-scoped approval audit reads

Refs #25920 and its original #25100. Base:3cce9a517b25863c00b48cfb3dd79b994ebc1044.

## Before and after

The scoped reader read max(500,n*64) global physical rows before filtering. Two target events separated by650 foreign events returned only the newer target for n=2. The repaired reader uses the existing strict reverse Dated_jsonl cursor until n matching rows or EOF, retaining only selected rows and the reverse reader's current chunk/line. It uses the same Domain_pool_ref.submit_io_or_inline boundary as the prior strict recent reader; no new pool or fallback is introduced.

There is no row TTL, tail guess, second writer, new store or persisted index. Malformed JSON, ambiguous owner metadata and I/O/layout failures in the visited suffix return typed Read_recent errors. Keeper identities compare exactly; prose never selects control flow. Global reads retain existing raw-row semantics. Row corruption older than a complete selected suffix is unvisited; directory layout validation can still reject older invalid entries. Append/writer locking and separately coverage-labelled resolved-history scan limits remain unchanged.

## Defined verification

Existing suite:test/test_keeper_approval_audit_timeline. Four new scenarios use actual Audit.record writes and verify clean receipts:650 foreign writes between target rows across physical days, immediate append freshness without store reset, full target EOF, global newest order and separate workspaces; malformed JSON between target rows versus corruption outside the selected suffix; missing/non-string/duplicate owner metadata; missing store versus an invalid file in place of its directory and zero-limit no-I/O.

Initial run40163708651 at5d50121d78ff4c7ca8ff6fa8ecfcefe8231ff764 FAILED before scenarios: the backend-error record expression was inferred as write_failure because read_error and write_failure share stage/detail labels. Prior source audits missed this compilability blocker. The repair explicitly annotates the existing read_error type at that return; no behavior/API change. Initial failure is retained separately. Three OCaml files parse; whitespace passes. No local Dune/typecheck or repaired-head scenario execution claimed. Source hashes are listed separately. Full regression unrun. Independent source review and selected execution must be recorded against the final head.

## Remaining scope

Sparse reads may visit the full retained audit store. This is correctness repair, not an owner/time persisted index or a latency bound. #25920 remains OPEN for that canonical requirement and trajectory scanning. No Gate authorization, actual HTTP/browser, installed runtime, fleet performance, merge or whole-issue completion claim.
