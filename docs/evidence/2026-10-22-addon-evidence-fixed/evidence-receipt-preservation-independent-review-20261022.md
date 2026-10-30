verdict: PASS head: d06fc9229f2d46597933526d06863e0473c87874 by: g01_context_response

# Evidence receipt and retained-result preservation: independent source review

No remaining P0–P2 finding after the application-observation follow-up. This is a bounded source verdict, not formal GitHub approval or proof that the changed binary has run.

## Exact scope

- Worktree: `/tmp/masc-addon-evidence-retained-20261022`.
- Reviewed base: `c3efec4db0a32c1bac8d298ccadd7506e06ec16f`.
- Final reviewed head: `d06fc9229f2d46597933526d06863e0473c87874`.
- Canonical complete diff: `c0b00fd09a1f9a81ff44776c18073b35a6cec6d69161b0caa50a2840b19ca683`.
- Complete delta: `bin/masc_tui.ml` and `changelog.d/44895.md`; no interface, server/API, model, runtime or unrelated requirement changes.
- The constitution/contributor/native-stack authority files at this base are unchanged from the previously fully read authority. Relevant TUI composite-read/workspace and OCaml typed-state guidance were consulted.

I first reviewed the uncommitted inventory-skip patch, found the application-reading loss below, notified the author, then independently read the final commit containing its correction. The author made the code changes; this reviewer did not edit, commit or push them.

## Actual historical symptom

I read the existing captures `13-retained-real-receipt.txt`, `14-receipt-and-row-after-refresh.txt` and their `transport-events.jsonl` under the supplied exact6f68 native observation directory. Capture13 has an actual preserved one-row evidence receipt, its original owner and selected row ID, but no result rows in the received view. Capture14 retains the same receipt/selected row ID and has that same original selected row again after refresh.

The recorded transport sends POST `/api/v1/lane-addons/evidence` at1792598308.9928389 and GET `/api/v1/lane-addons` immediately afterwards at1792598308.997795. The subsequent refresh sequence includes inventory plus `/slice?run_id=native-current-ui-proof`. These are original observations of the old binary. They corroborate the caller path and symptom; no fixed-candidate UI run was performed by this reviewer. Transport timing alone is not a response-body or source identity proof.

## Resolved finding: application observation was still being cleared

The initial patch skipped the post-Evidence inventory GET, but launcher preparation still classified Evidence as `Request` and set `application_reading=empty` (the prior code at5227–5229). `track_application` reads only `Application.value view.application_reading`, without falling back to `snapshot.configuration`. Previously a successful follow-up inventory repopulated this field. With the new receipt-only Evidence reply and inventory status `Unchanged`, that emptied prior application observation/failure would remain empty until a later independent read.

This was a concrete P2 against the stated preservation contract: preserving unrelated evidence could erase a previous Applied/Failed/Unavailable observation and its failure detail. Merely retaining a pending old ticket would also be incorrect after incrementing the request generation.

Final d06fc922 replaces `empty` with the existing `Masc_tui_lane_application.suspend view.application_reading` for Request operations. I read its implementation and interface: `suspend` clears only `in_flight` and retains the exact prior received result. A late old-ticket completion cannot match the retired ticket; a new generation can start its own read. This resolves the finding. Receipt-only Act/Subscriptions also retain their previous application result, while Attach/Observe/Detach still replace it when their existing post-operation inventory read returns. This does not make the preserved observation a new application read or new effect authority.

## Evidence does not require an inventory/application refresh

I read the actual server Evidence branch and `Lane_addon_store.freeze`. Preserve-only validates the original instance/binding/visibility and row IDs, writes content-addressed copies and returns their evidence receipt. It does not attach/observe/detach a worker, reconcile a declaration or modify the worker's observation rows. Keeper/Broadcast destinations add their existing publication/delivery effects but still do not require a worker inventory refresh as part of preserving those rows.

The final launcher therefore appropriately returns `reply ~receipt ?diagnostic ()` for Evidence: no replacement snapshot, no action receipt, and default inventory `Unchanged`. In the existing result consumer this preserves snapshot rows, row cursor, marked selection, existing detail-read marker and snapshot-read failure. It installs only the actual receipt and any diagnostic. The path no longer feeds inventory-only rows into detail reconciliation. Attach/Observe/Detach keep their old inspect path and inventory failure/result behavior.

The explicit impossible alternatives in the new inner match are unreachable from the enclosing Attach/Observe/Detach/Evidence branch; all request constructors are listed. No partial pattern or fallback converts a future request into Evidence behavior.

## Receipt ownership, navigation and workspace changes

The final patch retains the existing `Read_screen` target for Evidence. It does not bind a preservation receipt to an arbitrary newly opened Detail or replace that Detail's snapshot: `lar_snapshot=None` uses the currently owned view as-is. Navigation within the same generation can receive the original owner-labelled last receipt under the existing Read_screen contract. A newer Addon request changes generation, and the result handler drops a mismatched older generation before applying receipt or state.

Dispatch still captures the workspace authority and expected identity, rechecks them before POST, marks the request as an operation and wraps the reply in the original workspace envelope. Workspace authority replacement rejects the original completion; snapshot-reading authority withdrawal alone does not retroactively deny an already admitted operation receipt. With no follow-up snapshot there is no new observation to promote under retired read authority. The unchanged operation projection still preserves the difference between admitted receipts and invalidated GET observations.

The Broadcast branch still binds credentials, prepares the durable pending request, posts with that captured credential, acknowledges the actual returned receipt and returns an explicit Request_failure diagnostic if ACK tracking cannot be confirmed. UI `acknowledge_broadcast` and request-ID cleanup remain unchanged. The change does not re-post Evidence, fabricate a receipt, claim broadcast delivery from an ACK failure, or introduce a new retry authority.

## Failure and freshness boundaries

Previous detail-read and snapshot-read diagnostics remain unchanged because Evidence has no snapshot and inventory is `Unchanged`; application failures now remain through `suspend`. The ordinary current request/error field is still cleared when a new request begins and replaced by that request's actual diagnostic, which is existing request-notice behavior rather than removal of retained read failures. A failed POST still follows the existing Request_failure branch and does not publish a success receipt.

Independent visible-pane cadence and explicit refresh remain available to discover real inventory/application changes. This patch does not guarantee that a later legitimate fresh inventory cannot change a view, and it does not claim a corrected binary/UI observation. It removes this unnecessary Evidence-triggered inventory overwrite while preserving the existing refresh and ownership boundaries.

## Verification limits

Only direct source/interface/caller/consumer inspection, existing capture/log reads and canonical Git diff identification were performed. No local Dune, OCaml build/test execution, CI query/dispatch/watch, Docker/process action, browser/runtime mutation, source edit, ref/checkout mutation or approval publication occurred. No screenshot/text/layout test was added. The unrelated cancellation/re-request status reported by the author is not successful execution evidence and was not independently queried here.

A later exact-head execution should demonstrate the original retained row/selection and actual receipt together after preservation, retain an existing detail/application failure, and separately qualify navigation/workspace admission and Broadcast ACK recovery. Such execution remains a separate result from this source PASS.
