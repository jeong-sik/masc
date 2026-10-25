# Schedule drain dispositions before reaction projection

Refs #26430. Upper base is lower observation PR45897 head0ebfd17f0da3b5038d2ac1ccea6c813a5f6de1c3. This is the actual schedule projection/UI layer, not just the lower observer API.

The page resolves complete read-only queue state before reading the reaction ledger. It uses the existing durable occurrence index: latest incarnation, same-incarnation conflicts, transfer cycles, cached-target absence refresh, exact retired receipts. Every supplied read observes fresh bytes and replaces the displayed queue state; there is no separate pre-capture cache. Per-owner coherence is not a global cross-store transaction. The GET does not acquire the owner lock, mutate the queue, replay an outbox or invent reaction fields.

Dispatch and provenance checking share the complete source decoder. Full and compact sources must match the requested occurrence, payload digest, arrival time, urgency and source snapshot hash. Unprojected transfers retain their source authority and are checked too. Terminal completion/failure/cancellation and transfer projection produce explicit queue statuses; pending projections stay settling, failed attempts stay failed, and genuine exact absence with dispatch-only ledger evidence remains missed. An explicit ledger terminal contradiction stays invalid. Detailed evidence shows owner, transition, transfer target and terminal outcome. Calendar/KPI and lane matrix use one decision function.

## Selected validation

Local three-suite Vitest: 97 PASS, summarized in vitest-result.txt. Five changed OCaml source/interfaces parse; committed whitespace and eleven source hashes pass. No local Dune, typecheck or backend execution claimed. Full regression unrun.

The selected backend suite is test/test_schedule_consumer_dispatch. New defined scenarios dispatch real schedules and commit actual completion/failure/cancel/transfer through persistence. Inside the actual under-owner-lock callback, the real page encoder observes the committed state while the reaction ledger still contains dispatch only. Later explicit projection is checked. Completion is followed by another real terminal that retires its hot witness; the page must then resolve the compact exact receipt, and a corrupt receipt must remain read_error even though the ledger has an ACK. Another actual transfer occurs between target-first and source observations and requires a second fresh target read. Existing stale-occurrence and reaction-read failure cases remain selected. Printed SCHEDULE_DRAIN_PAGE rows are actual encoded page outputs for later cross-language evidence, not hand-authored backend fixtures.

## Source review repairs

Initial source head6563a4c8499226f1368e549347b9d0a5bd925011 failed independent review: two extracted bindings remained referenced, the source Keeper fixture was missing, pre-captured empty target observations could escape the resolver cache refresh rule, transfer provenance was omitted, and explicit ledger contradictions could become healthy completion. Repair78c26470dfa070a535e386e05646f2e08b6dd166 addresses those findings. Final independent review and requested selected execution must be recorded separately; parsing and TS tests do not establish backend compilation.

## Remaining evidence

Backend selected execution, actual page-row-to-frontend replay and visible browser QA are not yet established. No merge, installed runtime, live Keeper/provider, full regression, performance or whole-issue completion is claimed. #26430 remains OPEN pending these results and integration. Native stack submission/membership and exact final source review belong to separate receipts.
