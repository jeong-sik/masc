# A02 retained detail refresh: independent source investigation

Reviewer: bidi_open_tab_review. Read-only source + archived evidence review. No code/ref/GitHub/runtime mutation, CI query, build, parser or test execution. The private login file was not read or printed.

## Identity and observed evidence

- Actual observed fixed product: `7b16a9175711aefe744c5c704e038a42fd5b6b7b`, using archived actual TUI/server captures and API responses from the workspace named in a02-session.json.
- Shared checkout local HEAD: `4fff07da4516d871a7ef71260585afaedad6c776`. This is a local checkout identity, **not** current GitHub main. All three inspected TUI files there match product7b16.
- Fresh independent REST `branches/main`: `8feb8ea28f748c9e8c8ea905dc13b64671f04401`. Direct contents API reads at that exact immutable SHA retained under a02-remote-main-*; identity manifest is a02-remote-main-source-identity.json.
- Remote `bin/masc_tui.ml` blob `09cc2669927ca309b0c1bae90e56528a47e80478` is byte-identical to product7b16. Remote `masc_tui_lane_addons.ml` blob `35641af274b39494c84b941a8997dc69c52bdffb` and MLI blob `f87fe052c83814634123ad168c0518df94cf59f5` differ only by G04 connection_workers/read-only related-owner grouping. The relevant decoder/reconcile/read_target behavior is unchanged.

Archived evidence, without additional runtime actions:

- 06-on-detail.txt shows original attached detail with result SoundFont:stop_requested. SHA256 f3065cfcfc411333653183c9d2b5fac019b7ae5c115ed828970a5e7da964dab6.
- 10-off-application.txt preserves the same original row while the accepted file application is Off/cleanup confirmed; worker data in that older view is still attached. This demonstrates the application observation and worker/output refreshes are separate reads, not an off-save data-deletion receipt.
- Both11-off-retained-detail.txt and12-off-retained-refreshed.txt show the original detached detail with no result rows; identical capture SHA256 4b7dcfd664033db208cd9599642decb894c1b80411fc3dad9e676860d43dd76d.
- off-after-save.json has application inactive and original instance/incarnation `01a15e68-fe1a-7000-a88d-b24037b9d7c8`, presence retained, phase detached, observation_seq1 and rows_count1; inventory rows=[] is explicit.
- off-slice.json is complete=true and returns original row `01a15e68-fe1a-7000-a88d-b24037b9d7c8/1/7bbdaca358143a01ffa148fa9819a5151148984cdd7f4427062b53f1219baa9d`, lane `<same-instance>/phrase`, and retained coverage for that same incarnation. This disproves backend row deletion for this observation.
- Parent additionally observed history Enter briefly restore the original row before r/cadence erased it; that timing is parent-observed, while the supplied captures/API independently establish empty UI plus retained backend row.

## Confirmed P2: ordinary refresh drops the original detail read target

Present in the actual fixed product and inspected current remote main; blocks A02 retained-results acceptance. This is not a claim that the G01 application-state change created the pre-existing defect.

Causal path (masc_tui.ml line references are identical at7b16 and remote8feb):

1. `launch_lane_addons` line5163 defaults to `Read_screen`. Lines5192–5194 derive initial_detail only from explicit `Read_detail(id,incarnation)`.
2. Inspect lines5226–5247 reads fresh inventory. It fetches retained `/slice?run_id=...` **only** when that captured exact detail target is found in the fresh inventory with Retained_binding. With Read_screen, it returns inventory output alone, which legitimately omits retained rows in this reproduction.
3. The r handler lines25546–25552 chooses Slice only when overview_mode is Retained_runs. An originally live detail stays Current_installations after its worker becomes retained; that branch chooses Inspect and supplies no target. Even the direct Slice path supplies Read_screen, so it is not scoped against leaving the original detail.
4. Lane_addons_loaded lines17475–17523 accepts a matching generation; Read_screen is unconditionally wanted (`read_still_wanted`, original ML1451–1454/remote1455–1458). It calls reconcile_snapshot, which replaces output with received inventory output and unanchors the now-absent row (pure ML426–469). This creates an empty received detail even though retained storage still has that row.
5. The same omission repeats in the visible refresh cadence lines32775–32787. History Enter explicitly carries Read_detail and can load the slice, but the next cadence's Inspect can erase it again. A fix in only the r arm will therefore leave the reproduced behavior.

Other ordinary refresh callers with the same target-loss risk:

- authority/reconnect recovery line15040;
- terminal action-status follow-up Inspect line17529;
- r line25552;
- visible cadence line32786.

Explicit navigation is different and must retain its intent: installation Results jump14265 uses Read_installation_results; manual-instance open14323 and history/current Enter25495 use Read_detail. General CLI/command11435, palette27376 and Lanes open31903 are navigation/request entrypoints, not automatically identical to an existing detail refresh. Audit them explicitly rather than blanket-rewriting every call.

## Minimum coherent repair

Use a single pure typed projection of the current screen's ordinary refresh intent (existing read_target, exact Detail id+incarnation), then have the actual r/cadence/reconnect/follow-up Inspect paths pass that target. Keep Overview as Read_screen and preserve explicit Read_installation_results jumps. Capture the target before async work; do not infer it from whatever instance is selected when the reply arrives.

The existing fresh-Inspect→exact retained target lookup→run-scoped Slice sequence is already the correct starting seam. The fresh matched instance supplies run_id; do not select a replacement by installation ID/title/path/run alone. An originally live detail can become retained without toggling global history mode, so history mode must not decide whether this original detail is eligible for its retained slice. Prefer a shared refresh plan used by all ordinary read callers; keep explicit raw Slice/query commands distinct.

Preserve the existing generation and workspace envelopes, and the read_still_wanted exact detail pair. A late original-detail answer must not repaint a different detail or trigger navigation. Hidden same-owner cache handling should remain intentional; cache identity is not authority to open a pane. Preserve fresh configuration/application facts separately from a retained result read.

Do **not** blindly change the optional default target for every request to Read_detail. Attach/Observe/Detach/Evidence/Act and Action_status have receipts that must remain recoverable after navigation; scoping their whole reply as a disposable detail read could discard an accepted effect/unknown receipt. Apply the target change to actual ordinary read planning or split receipt application from scoped detail observation. Do not add refresh timers, retries, redispatch, an output cache keyed only by run or a second browser/worker selection model.

## Additional failure/omission risk to cover

The current Inspect composite has another source-supported loss path at5239–5246: successful inventory + failed retained Slice returns the new inventory snapshot with Detail_read_failure. The handler reconciles that snapshot first, so previously received retained result rows disappear even on a transient history failure. This was **not** independently reproduced in the provided runtime capture. A repair should preserve the previous successfully received payload belonging to the same exact original detail while exposing the new detail failure/freshness separately, rather than showing a failed Slice as a fresh empty result. Do not merge another owner's rows or treat cached output as current authoritative data. An explicit successful empty Slice must still be allowed to produce an empty observation.

Current row filtering is an important retained guard: rows_in_screen resolves row ownership against snapshot.instances then checks exact target id/incarnation (ML316–341). Run-scoped slices can contain multiple incarnations; do not remove this filter or let same-run replacement results stand in for the original. A missing/mismatched exact target in fresh inventory must not silently fall back to another worker or perform its history request.

## Focused request/state validation (no wording/layout assertions)

Exercise the **actual planner/launcher composite and reply reducer** at the existing transport seam (or a narrowly extracted pure function actually used by those callers). Do not add tests that only mirror an unused helper or count rendered strings.

1. Original live Detail(A,incA), then fresh inventory reports exactA retained with empty inventory output. Manual refresh and the same shared cadence plan must issue Inspect then Slice using freshA.run_id, carry Read_detail(A,incA), and reconcile the original result ID back into the same detail. Test independent of Current_installations versus Retained_runs, presentation and focus.
2. A retained detail initially opened through history gets a successful Slice; a later visible refresh must preserve/reload that same row rather than downgrade to inventory-only output. Assert exact request target, applied snapshot/output membership and selected_row identity, not text.
3. New workerB may share installation ID/title/path/run withA. Fresh inventory containingA+B must still read/displayA only; missingA or sameid with another incarnation must produce no B fallback and no invented result. Exercise row_owner filtering when the run Slice returns both owners.
4. Hold the old detail read; leave detail or move to another exact pair before completion. Its scoped response must not replace the new detail or navigate. Superseding generation and withdrawn/switched workspace responses remain refused; same-workspace recovery plans against the current original screen. Verify loading settlement without losing another request's ownership.
5. Successful fresh inventory + failed Slice preserves prior exactA result as a retained observation plus typed detail failure; initial no-prior-output failure stays unknown/failed. A later successful empty Slice is distinguishable and may clear the old result. Inventory failure must preserve the prior snapshot and expose inventory failure as it already does.
6. Keep Action_status/Act and other effect receipt retention intact when the operator navigates; a terminal action's follow-up observation uses ordinary refresh intent without submitting the action again. Preserve pending-action priority, editor/document/installer/evidence guards and existing single in-flight admission.
7. Existing explicit Read_installation_results behavior, Overview refresh and raw query Slice must retain their original semantics. Do not unexpectedly reopen a cached detail on a navigation command.

These are validation targets, not executed checks. After a bounded source repair and normal current-head independent review, repeat the actual isolated TUI Off→retained detail→manual refresh→visible cadence and Off→On replacement observations. Confirm original row and distinct replacement identity using retained API evidence. No visible/UI completion is established by this source report.

## Actual repair source review, PR #44838

verdict: PASS head: b217eacd614a4845aef270f62f6f27f182de6d54 by: bidi_open_tab_review

Bounded source verdict for the original read-target repair only. Base `8feb8ea28f748c9e8c8ea905dc13b64671f04401`; complete5-file canonical diff `d082102f2b65dc8ac263e3b91c9f8583e7b3ea686c3ad291585588b7343951f1`. Read all production ML/MLI, state/request test and own-number changelog changes directly from this immutable object. This local object includes implementation28c00de09c0 plus changelog only; publication identities were not queried for this new PR in this review.

The actual implementation chooses request_read_target from the captured original view only when no explicit target override is supplied. Only Inspect and Slice bind Detail(id,incarnation); every other closed request constructor remains Read_screen. Existing explicit installation-result/manual-detail targets remain unchanged. The central launcher is used by manual refresh, cadence, authority recovery and terminal-action follow-up, so the repair closes those callers together rather than only changing a key arm. Existing fresh retained-lookup and slice transport are reused without new polling, replay or lookup authority. The selected exact pair travels in Lane_addons_loaded to the existing generation/workspace and read_still_wanted guards. Actions, status/evidence/subscription and save ownership are not rebound to disposable detail observations. Both nested matches enumerate constructors; the new interface/type owner and direct calls introduce no new Dune library dependency by source inspection.

The added test exercises the exported planner actually used by the launcher together with existing response-admission decisions: original Inspect/Slice target, different incarnation/worker and departed-detail refusal, Overview behavior and effect/status receipt applicability after navigation. These are request/state checks, with no new displayed text/layout assertion. It does not execute the launcher HTTP sequence, fresh live-to-retained transition, whole async reducer, new OCaml executable or actual repaired UI; those remain validation limits, not implied coverage.

No additional P0–P2 introduced by this bounded five-file delta found. The separate pre-existing successful-Inspect/failed-Slice prior-output loss risk described above is **not changed or resolved** by this target-only repair and should remain separately tracked. This PASS must not be read as that failure-path fix, a repaired native TUI observation or A02 completion. The captured7b16 empty-detail observation is old-product failure evidence; new sourceb217 has not been executed by this reviewer. No formal GitHub approval issued.
