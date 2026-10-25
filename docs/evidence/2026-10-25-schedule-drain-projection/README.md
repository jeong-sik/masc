# Schedule drain dispositions before reaction projection

Refs #26430. Upper base is lower observation PR45897 head311ae801c6137a788637b7b5401c458c2e5301cf. The external update from0ebfd17f changes only the changelog fragment; its feature code and test blobs are identical. This is the actual schedule projection/UI layer, not just the lower observer API.

The page resolves complete read-only queue state before reading the reaction ledger. It uses the existing durable occurrence index: latest incarnation, same-incarnation conflicts, transfer cycles, cached-target absence refresh, exact retired receipts. Every supplied read observes fresh bytes and replaces the displayed queue state; there is no separate pre-capture cache. Per-owner coherence is not a global cross-store transaction. The GET does not acquire the owner lock, mutate the queue, replay an outbox or invent reaction fields.

Dispatch and provenance checking share the complete source decoder. Full and compact sources must match the requested occurrence, payload digest, arrival time, urgency and source snapshot hash. Unprojected transfers retain their source authority and are checked too. Terminal completion/failure/cancellation and transfer projection produce explicit queue statuses; pending projections stay settling, failed attempts stay failed, and genuine exact absence with dispatch-only ledger evidence remains missed. An explicit ledger terminal contradiction stays invalid. Detailed evidence shows owner, transition, transfer target and terminal outcome. Calendar/KPI and lane matrix use one decision function.

## Selected validation

Local three-suite Vitest: 97 PASS, summarized in vitest-result.txt. Five changed OCaml source/interfaces parse; committed whitespace and eleven source hashes pass. No local Dune or typecheck was run. Actual selected backend execution and replay evidence are recorded below. Full regression unrun.

The selected backend suite is test/test_schedule_consumer_dispatch. New defined scenarios dispatch real schedules and commit actual completion/failure/cancel/transfer through persistence. Inside the actual under-owner-lock callback, the real page encoder observes the committed state while the reaction ledger still contains dispatch only. Later explicit projection is checked. Completion is followed by another real terminal that retires its hot witness; the page must then resolve the compact exact receipt, and a corrupt receipt must remain read_error even though the ledger has an ACK. Another actual transfer occurs between target-first and source observations and requires a second fresh target read. Existing stale-occurrence and reaction-read failure cases remain selected. Printed SCHEDULE_DRAIN_PAGE rows are actual encoded page outputs for later cross-language evidence, not hand-authored backend fixtures.

## Source review repairs

Initial source head6563a4c8499226f1368e549347b9d0a5bd925011 failed independent review: two extracted bindings remained referenced, the source Keeper fixture was missing, pre-captured empty target observations could escape the resolver cache refresh rule, transfer provenance was omitted, and explicit ledger contradictions could become healthy completion. Repair78c26470dfa070a535e386e05646f2e08b6dd166 addresses those findings. Both independent source sessions passed repair78c26470. Rebase onto the external fragment-only parent update and final documentation require refreshed head/base identities. Requested selected execution must be recorded separately; parsing and TS tests do not establish backend compilation.

## Remaining evidence

Selected backend execution, producer-row-to-frontend replay and controlled browser QA now have the evidence below. No merge, installed runtime, live Keeper/provider, full regression, performance or whole-issue completion is claimed. #26430 remains OPEN pending integration. Native stack submission/membership and exact final source review belong to separate receipts.

## Stack and prerequisite observation

The prior unrelated gh-stack editing process was confirmed gone. gh stack init adopted the two own branches. gh stack submit then refused with “Stacked PRs are not enabled for this repository”. This is branch-chain draft PR45901 on parent45897, not confirmed native membership. The parent externally advanced to311ae801 with only its fragment correction; the whole local two-layer chain was restacked using gh stack rebase --no-trunk, preserving that update.

Actual prerequisite run40178416108 completed SUCCESS at0ebfd17f: 47 selected ledger cases in0.173s, including complete-state owner-lock observation/no durable byte changes and full-state generation-change refusal. The current parent has identical feature/test inputs; this is not a new execution at311ae801. It does not execute this upper layer.

## Actual upper execution and producer-to-UI evidence

Run40179723721 completed SUCCESS at exactly509df9de6eb0a433b1be632ca97adc2353e1f78c: all56 selected schedule consumer cases in2.677s. The checkout, five new scenario verdicts and actual summaries were read. backend-run-40179723721.txt retains those lines and14 actual SCHEDULE_DRAIN_PAGE records. backend-provenance.json binds the original full log digest and parser. produced-pages.json contains those exact decoded rows, including occurrence IDs and the malformed-retired-receipt error. Existing suite WARN/ERROR rows are deliberate malformed-store/shutdown/fence fixtures; they are not counted as live incidents.

The archived produced-page-replay.test.ts ran14 PASS against those rows through the actual exact-lookup decoder, aggregate normalizer, drain/KPI functions and detailed component. It verifies original producer identities, settling before projection, completed/failed/cancelled outcomes, transferred target pending, read_error despite a recorded ACK, and unchanged original reaction evidence. It adds no row fields or fake ACKs. The previously executed97-case selection retains genuine dispatch-only misses, terminal contradictions and read failures; the existing actual backend stale-occurrence negative also passed. These are distinct checks, not a claim that a hand-authored miss row came from this run.

Ego task45 navigated the actual candidate ScheduleSurface, whose public HTTP client/resource and router consumed these rows in a controlled one-row envelope. It opened the list, completed filter and exact occurrence drawer, and then followed the canonical route across four actual scenarios. All four reported queue-miss KPI0 and preserved exact post IDs. Screenshots were visually inspected for unprojected completion, projected failure, corrupt retired receipt and a transferred pending target. browser-observed.json records the actual results. This proves candidate browser behavior with controlled HTTP, not an installed server/provider/fleet. The envelope intentionally omits unrelated live_supported_non_terminal_evidence: the existing UI shows that contract as unproven rather than inventing live evidence. Fixture timestamps remain the real1970 test timestamps.

The first HTML fixture incorrectly let Vite prepend its base twice to stylesheet URLs; it produced unstyled content. The fixture links were corrected to the actual source CSS paths, including schedule.css, and all final screenshots use loaded candidate styles. No production CSS or application behavior changed. Task45 finished with no retained agent pages; only own Python18120/Vite18200 processes were stopped and verified absent. Ego Lite reported an available update; no upgrade was run.

## Replay procedure

From the repository root, copy this directory's produced-page-replay.test.ts to dashboard/src/components/schedule/produced-page-replay.test.ts. From dashboard run:

    ./node_modules/.bin/vitest run --config vitest.config.ts --no-file-parallelism --maxWorkers=1 src/components/schedule/produced-page-replay.test.ts

Remove only that temporary copy afterward. For browser replay, run browser-server.py from its evidence directory (it prints an ephemeral loopback port), copy browser-harness.html to dashboard/produced-schedule-qa.html, and start candidate Vite with MASC_DASHBOARD_PROXY_TARGET pointing to that printed loopback port. Visit /dashboard/produced-schedule-qa.html?case=completed%3Aunprojected#/schedule. The one-row envelope is controlled; producer row fields stay unchanged. The archived round-visible.mjs records the observed session's absolute paths/space45; do not blindly replay the finished task or old process IDs. Start a new authorized browser task and use its actual page/port handles. Remove only the temporary HTML when done.

All additions after the executed509df9de head are evidence documents and artifacts. Eleven production/test blobs remain identical; the old run is not relabeled as a new execution of the documentation head. Final source review, PR state and integration remain separate receipts.
