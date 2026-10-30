# Original Ask final outcome independent of queue publication

Source comparison base: `8227b4f5282e131577973ce8480a17f425a4eaca` (#43782).
Source boundaries only; no executed runtime sample or speed measurement.

## As-Is / To-Be

POST facts already survived shared-mailbox waits, but the canonical reread Result
remained local until a cancellable final queue add. The original workspace/read
scope lived in that enqueue closure. Losing or delaying final publication could
leave the UI without the actual terminal pair.

The request now owns a separate once-only final cell. The actual receipt/reread
pair and monotonic observation time are published immediately after reread return,
before its observation logger. The outer path covers actual pre-reread and
exception-mapped errors. A later publication cannot replace the first pair.
Worker closure preserves both actual facts and closes empty cells without
inventing an answer or completed reread.

| Source boundary | Before | After |
| --- | --- | --- |
| Final queue adds after canonical reread | 1 | 0 |
| Early POST-result queue adds | 0 | 0 |
| Actual final pair independent of queue delivery | No owned cell | Original request cell |
| Original final workspace/read scope | Enqueue closure | Same values captured on submission |
| UI completion projection | Existing operation projection | Same projection |
| Receipt from a completed POST after read retirement | Retained | Retained |
| Retired/unconfirmed GET accepted using current read scope | Refused | Refused |
| Closure before a reread Result exists | No completed reread | No fabricated completed reread |

UI drain keeps queued identity changes ahead of recovered facts and POST receipt
recovery ahead of final recovery. Final recovery consumes a transport offer once,
then builds Workspace_scoped with the original authority and read nonce/None.
It uses the existing Ask_answer_done admission/projection and actual captured
Results. No read scope is reconstructed from current UI state. Raw facts remain
unchanged in session history even if UI projection refuses their reading or a
foreign workspace discards the transport.

Terminal application additionally checks the original current/inflight submission
so duplicates or superseded requests cannot settle a newer gate. This check is
not read authorization: the existing operation-outcome rule can retain a known
POST outcome while identity confirmation is unavailable; feedback/GET admission
still use their original rules. Publication and transport recovery do not close
drafts or declare an answer accepted. Only normal admitted UI completion does.

The new final cell is separate from the early POST receipt: these are distinct
observations with independent completion and cancellation boundaries. They share
one submission identity and session owner. Pending scans exclude closed or
consumed owners; history retains actual facts. This is not restart durability,
immediate feedback under continuous queue traffic, actual paint, first usable
input, useful Keeper work or a measured latency gain.

No new HTTP/model calls, Tool effects, publication fibers, protected queue waits,
queue capacity, frame budget, timeout, retry, cache, request generation or UI row.
Both worker finalizer operations are synchronous atomic closure. Original
workspace check and POST-to-reread causality remain. The regular UI input/drain
cadence is reused; no timer is added.

## Authored evidence and limits

The existing compound full-Eio-stream/cancellation scenario now captures the
final pair too, keeps it through cancellation/closure, checks once-only recovery
and tests the production transport factory plus operation projection. It covers
read-epoch retirement while POST survives, original absent read scope, foreign
workspace rejection, duplicate current/inflight gating, preserved raw results,
POST-only cancellation and empty closure without fabricated completion. The
fixture intentionally blocks its own notification; production final publication
has no queue add. No real answer endpoint, canonical HTTP reread or screen test
runs in that fixture. Other submission constructors carry the new captured scope
and cell. All scenarios remain unexecuted.

Author checks are parsing-only and diff/changelog hygiene. Typing, assertion
execution, runtime cancellation/saturation, CI, independent review, native/model
runs, installation/restart, visible UI and matched speed remain unverified.
