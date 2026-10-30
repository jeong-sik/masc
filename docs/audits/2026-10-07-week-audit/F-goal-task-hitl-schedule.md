# Domain F audit: Goal, Task, HITL approval queue, Schedule (2026-10-07)

Audited at main checkout HEAD 7fb34c7172 (origin/main moved to 58ebce7f12 during the audit; the 5 newer commits are TUI tests and #41407 chat waiting, none in this domain). Read-only. Baseline: docs/audits/2026-10-01-week-audit-*.md.

## 1. Change flow by day (domain paths)

- 09-30: Goal shared + acting identity recorded (#39975, the change that left goal_notification rows on disk -> D5-01/D7-01); Goal due/priority edits become events (#39951); verifier Snapshot before pass commit (#39978); schedule withdraw-every-pending-wake (#40006) and three schedule perf patches (#40022 #40026 #40034); stalled-notice shows verifier runtime (unnumbered 57d3a816c1).
- 10-01: approval queue split into codec/result/state/exact-transition (#40119 #40122 #40229 #40232, merge #40235 on 10-02); `resolve_keeper_wake_target` removed (#40407, D5-11); Task GC archive-first (#40427, D6-11); cron single-value step rejected (#40460); Goal history ordered by snapshot version (#40369); Goal notice receipts (#40248).
- 10-02: GC archive snapshot serialised (#40571); Goal audit transaction types (#40832); review approval bound to full diff (#40356); Task census payload/paging (#40654 #40655).
- 10-03: CI-only changes, nothing in domain code.
- 10-04: verifier retry keeps candidate identity (#40997); Goal transient verification retry on same proof request (#41003); committed approval delivered durably to producer (#41004); Goal proof audit recovery (#41053); Goal cancellation audit (#41134); Goal notifications passive + outbox identity validation (#41136); cron wildcard-step day matching (#41021).
- 10-05: no domain code commits (CI/release harness only).
- 10-06: Goal Pause/Resume, Block/Unblock restored (#41151); Goal drop requires reason (#41357) and cancels unclaimed Tasks (#41342); Goal notices appended on calling fiber (#41237); verifier watches review one model turn at a time (#41312); Lane activity flag (#41162); goal_list rollup schema (#41289).
- 10-07: nothing in domain code at HEAD (Goal creation feasibility is open PR #41399).

## Live snapshot (read 2026-10-07 ~04:40 KST, read-only)

- `goals.json` v132: 29 Goals = Executing 11, Completed 6, Dropped 12, **Verifying 0**, pending_events 0, pending_notifications 0. (10-01: 22 = Executing 5, Verifying 2, Completed 5, Dropped 10.) One Goal completed in the week (goal-keeper-automation, 10-05); v0.49.0 Goal was dropped 10-06. Three Executing Goals are past due with no review ever (`last_review_at` null): due 10-03 x2, 10-06 x1.
- `goal-verification-runs.jsonl` since 10-01: committed 1 (10-04 13:31), deferred 22, cancelled 1. 19 consecutive deferrals for goal-keeper-automation 10-03 07:23 -> 10-04 13:15, each ~901 s; details: 15x `glm-5.1 was retired at 2026-09-25` on `ollama_cloud.ollama-cloud-glm-5-1`, 7x claude_code 429 quota. The live verifier lane has since been changed (`runtime.toml:66-78`: glm-5.3-flash + deepseek-v4-1-flash + 5 claude_code CLI slots), no retired slot now.
- `verification-runs.jsonl` (Task verdicts, 18 MB, 2,996 register / 2,992 complete, 4 never completed): 10-03 0 verdicts / 137 not_reviewed; 10-04 28 / 406; 10-05 167 / 261; 10-06 69 / 0 not_reviewed. Throughput recovered on 10-06.
- `tasks/backlog.json` v13906: 1,207 Tasks = cancelled 668, done 458, todo 64, in_progress 17, **awaiting_verification 0** (10-01: 35). pending approvals/rejections 0. `tasks-archive.json` last written **09-20** (GC has not run for 17 days).
- Gate: `gate/mode.json` = `always_allow` (updated_by masc-tui 2026-09-23T03:41Z). No pending log (only `pending.log.jsonl.lock`), so the Manual/Auto-judge HITL path has still never run live. Two orphan `.atomic_*.tmp` files (15 MB + 6.7 MB, 09-04) sit in `gate/`.
- `schedules.json` 4.1 MB (+`.last-good` 4.1 MB), rewritten every few seconds (mtime 04:39:55 during audit).

## 2. Baseline (10-01) findings: status at HEAD

| id | 10-01 | status now | evidence |
|---|---|---|---|
| D5-11 `resolve_keeper_wake_target` stub | P2 | **Fixed** by #40407 (10-01) | `rg resolve_keeper_wake_target lib` -> 0 hits |
| D5-10 TUI/dashboard schedule edit sets `result_delivery` none | P2 | **Still open**, untracked | `server_routes_http_routes_activity.ml:166-169` passes `~channel:None`; `tool_schedule.ml:743` stamps on every write incl. update; `schedule_payload_projection.ml:179-190` replaces stored `result_delivery` with `{"policy":"none"}` |
| D6-11 Task GC deletes before archiving / no schedule | P2 | **Order fixed** (#40427, #40571); **no schedule still open** | archive last write 09-20 |
| D6-09 image evidence accepted at submit, unreadable at verdict | P2 | **Still open in code** (no capability check in `keeper_tool_task_runtime.ml`, 0 hits for image/media/capabilit); live impact now 0 (awaiting_verification 0) | |
| D6-03 / D7-02 single verifier slot | P1/P2 | **Mitigated by config** (2 HTTP + 5 CLI slots); code half of D7-02 (any wake re-reviews every Verifying Goal) **still open, latent** (0 Verifying) | `goal_verification_agent.ml:118-145` lists all Verifying Goals on each `request_scan` |
| D6-08 `operator_routed` rows block registry compaction | P2 | **Still open** (first 4 completes in `verification-runs.jsonl` are `operator_routed`; file 18 MB) | head of file |
| D7-03 ask-answer route open to Worker | P3 | not re-checked (Access Control audited elsewhere) | |
| D8-12 unreadable Goal due date | P2 | see F-04 below | |
| HITL live mode always_allow | note | **Still always_allow** | `gate/mode.json` |

## 3. Findings (new this audit), ranked

### F-01 P1 (fixed in-week, record only): one Goal notice blocked 34.5 h and wrote ~41k WARN lines/day
- Where: `lib/goal/goal_delivery.ml:42-57` (flush) called from the maintenance loop `lib/server/server_bootstrap_maintenance.ml:775-779`; introduced by #41053 (merged 10-04 08:24Z, new `Goal_delivery`), fixed by #41237 (merged 10-05 18:09Z, appends on the calling fiber).
- Live evidence: `wmsg-29f11d09…` failed `Eio_guard.Non_eio_mutex_context(0)` every minute from 10-04 13:45Z to 10-06 00:14Z: 2,052 `goal effect outbox delivery deferred` lines, plus `keeper_chat_store: user append-once failed` 1,425/day for each of 28 keepers on 10-05 (the notice fans out to the whole fleet snapshot, `goal_delivery.ml:19-36`).
- Tick: before fix, open (same notice retried each minute, never converges, one WARN per recipient per minute). After fix closed: `goals.json` pending_notifications = 0.
- Lesson already applied: the new tests call `Eio_guard.enable ()` (`test/test_goal_notification_contract.ml:13-17`). Confidence High.

### F-02 P2: Goal verification spends 900 s per attempt on a deferral that names only the last candidate's error
- Where: `lib/goal_verification_agent.ml:687-716` (retry armed for `Not_reviewed { retryable_runtimes = _ :: _ }`), `118-145` (every scan lists all Verifying Goals).
- Live: goal-keeper-automation sat in Verifying 10-03 07:23Z -> 10-04 13:31Z (~30 h), 19 deferrals each 901-907 s, ~16 min apart. The recorded `detail` was `glm-5.1 was retired at 2026-09-25` (15x, slot `ollama_cloud.ollama-cloud-glm-5-1`) or claude_code 429 (7x). A model retired 9 days earlier was still a verifier candidate and answered `Invalid request (unknown)` — a permanent refusal classified as retryable. Operator has since replaced the lane slots (`runtime.toml:66-78`), so this does not recur today.
- Tick: N retries, each holds one of `max_concurrent_reviews = 4` (`goal_verification_agent.ml:136`, unexplained constant) for 900 s; converges only when some candidate answers. Open while every candidate refuses permanently.
- Fix: classify a provider "model retired / unknown model" refusal as a permanent candidate failure (typed, Domain A owns the classifier) so the lane walk skips it and the deferral is non-retryable when no other candidate remains; record per-candidate outcomes in the deferral, not only the last one. Confidence Med (the 900 s total is consistent with a hung earlier candidate plus the final instant refusal; per-candidate timings are not in the ledger).
- Tracked: D7-02 covers the rescan part; the retired-model classification is untracked (`gh pr/issue search "retired model"` empty — see Domain A).

### F-03 P2: TUI/dashboard schedule edit still erases `result_delivery` (D5-10, unchanged)
- `server_routes_http_routes_activity.ml:166-169` stamps `~channel:None`; `tool_schedule.ml:741-743` runs the stamp on Update as well as Create; `schedule_payload_projection.ml:179-190` replaces the stored value with `{"policy":"none"}`.
- Scenario: a Keeper creates a recurring wake with `reply_to_origin` to a Slack thread; the operator changes only the interval in the TUI; every later occurrence's result is no longer delivered to that thread. No error anywhere.
- Fix: on `Update_schedule`, when the request carries no explicit `result_delivery`, copy the stored one from `authorize_row_change`'s `stored` (already loaded at `tool_schedule.ml:757-759`) instead of stamping. Confidence High. Untracked.

### F-04 P3: D8-12 data still present but now harmless; Goal overdue notice no longer exists, `goal_due.mli` still describes it
- `goals.json` goal-1790663276268-59e (Completed 10-01) keeps `due_date = "2026-09-29T21:00:00Z"`, which `Goal_due.read` returns as `Unreadable_due_date` (`goal_due.ml:28-49`). New writes are refused (`goal_store.ml:815-826`). Candle `candle_appraise.ml:49-55` would emit `Payout_failed` only if that pass were appraised; its pass predates Candle going live.
- #39975 removed the owner overdue notice (diff hunk with `Goal_due.is_overdue` in the notice builder); only the TUI Overview colours "overdue" (`bin/masc_tui_overview_goals.ml:106-113`). `goal_due.mli:3-5` still says the overdue notice reads it. Live: 3 Executing Goals past due (10-03, 10-03, 10-06) were never reviewed and no Keeper is told. Fix: delete the stale mli sentence; whether shared Goals need an overdue signal is an operator decision. Confidence High.

### F-02 addendum: the Task verifier hit the same wall, with measured cost
- `verification-runs.jsonl`, outcome `not_reviewed`, summed `elapsed_s`: 10-02 38 attempts / 15.8 slot-hours (26 Tasks); 10-03 137 / 26.2 h (46 Tasks, **0 verdicts**, 136 of 137 = claude_code "hard quota exhausted"); 10-04 406 / 68.6 h (51 Tasks; 54 claude_code quota + ~77 retired glm-5.1); 10-05 261 / 38.1 h. 10-06: 0 not_reviewed after the lane change.
- Retry is armed whenever any candidate's error `Agent_core.Error.is_retryable` (`lib/task/anti_rationalization.ml:637-641`). A 429 from claude_code makes the whole attempt retryable, and the retry walks the retired slot again. "Hard quota exhausted" did not stop the verifier from calling claude_code 136 times on 10-03, so the exact lane is not reading a durable rest record (Domain A D1-01/L2-04, not re-derived here).
- Tick: open while all candidates refuse; each tick re-walks every slot for every waiting Task (~8 attempts/Task/day on 10-04). Converged 10-06 only through operator config.

### F-05 P2: `schedules.json` is 4.1 MB of which 56% is notes and 92% of schedule rows are finished (D5-02 / D5-07 still open, measured)
- Live composition: `notes` 4,243 rows / 2.30 MB (1,845 = 43% name a schedule no longer in the ledger), `wakes` 1,130 / 1.14 MB (all `succeeded`), `schedules` 655 / 1.03 MB of which **53 live** (50 scheduled + 3 due) and 602 terminal (361 cancelled, 240 succeeded, 1 expired). 20 wakes older than 7 days survive because their schedule was cancelled/expired and "a cancellation writes no time of its own" (`schedule_store.ml:898-910`).
- Every change rewrites the whole file and its `.last-good` (8.2 MB). 10-06 had 570 dispatches and 500 `due_changed` ticks (system_log_2026-10-06), so the write volume is several GB/day for 53 live schedules.
- `schedules_forgotten_per_pass = 64` (`schedule_store.ml:918`) is a per-pass cap; justified in its comment, flagged only as a cap.
- Fix (unchanged from 10-01, still the smallest correct one): move notes to their own append-only file keyed by schedule_id, give Cancel/Expire a `finished_at` so the existing 7-day rule covers them. Confidence High.

### F-06 P2: Task backlog never shrinks: 95% of `backlog.json` bytes are finished Tasks, and a bulk cleanup rewrote it 440 times
- Live: 1,207 Tasks, 1,126 terminal = 3.96 MB of 4.15 MB. `tasks-archive.json` last written 09-20; GC runs only through the `masc_gc` tool (`lib/tool_misc.ml:79` is the only caller of `Workspace.gc`), D6-11's schedule half is still open.
- 10-06 08:43-08:44Z and 16:34Z: 440 manual cancellations (masc-tui, codex-mcp-client, "Unclaimed for 30+ days…"). Each one is a full rewrite of a 4.2 MB file plus `.last-good` (~3.7 GB written for one cleanup), and none of them reached the archive.
- Tick: open — backlog grows by every Task ever created; GC is the only shrink and nobody schedules it.
- Fix: run `Workspace_gc.gc` from the maintenance loop at the same cadence as schedule retention (now archive-first and serialised by #40427/#40571, so it is safe to automate); the retention window is the existing `~days` argument. Confidence High. Tracked as D6-11 (no open PR).

### F-07 P3: Goal FSM has a second writer for Executing -> Verifying
- `workspace_goals.ml:705-713` (`request_current_proof`) sets `phase = Verifying` by record update after its own `match goal.phase` instead of calling `Goal_phase.decide_transition ~action:Request_complete` (`goal_phase.ml:111`). Today the two agree (Executing|Verifying -> Verifying), so no wrong outcome; a future change to the matrix would not reach this path. Fix: derive the phase from `decide_transition`. Confidence High.
- Task FSM is exhaustive (`workspace_task_lifecycle.ml:58-270`, no `_ ->` arm). Operator recovery and rejection reset to Todo outside `decide` (`workspace_task.ml:326-336`, `466-473`) but check the source state exhaustively and (recovery) the backlog version. CAS: only operator recovery passes `expected_version` (`operator_task_recovery_command.ml:141-157`); Keeper/MCP transitions rely on re-deciding under the backlog lock, which is sufficient for status. Goal writes have no `expected_version` at all: `transact_goal` re-reads under the lock, upsert is last-writer-wins on title/metric/target/due/priority.

### Verified OK (no finding)
- **Approval queue split (10-01, #40119 #40122 #40229 #40232)**: 5,152 -> 3,182 lines in `keeper_approval_queue.ml`. Of 210 pre-split top-level names, 209 still exist; the missing one is the alias `normalized_input_hash = request_fingerprint`. 77 moved functions are body-identical after stripping comments/whitespace/module qualifiers; the 4 shrunken `*_summary_exact_attempt_with` functions now call `Keeper_approval_queue_exact_transition.{bind,release,quarantine,complete}`, and `bind` (`exact_transition.ml:13-60`) is arm-for-arm the pre-split match (`git show e126a20e72:lib/keeper/keeper_approval_queue.ml`). No behaviour lost.
- **Restart with a pending approval**: the queue is "durable, nonblocking" (`keeper_approval_queue.mli:1-4`): no turn waits on it; `install_persistence` reloads it at boot and the resolution wakes the originating Keeper lane. In-flight exact attempts are reclassified to `Exact_restart_quarantined` / `Exact_released_recovery_required` (`keeper_approval_queue_state.ml:60-112`). The chat-hook path is in-memory with a 180 s wait and a 900 s late-answer memory (`keeper_late_approval.ml:43,58`); a restart forgets a late answer and the operator is asked again. Closed. Never exercised live: Gate mode is still `always_allow`.
- **Schedule firing**: 10-06 570 dispatches, 0 failed, 127 hold-start lines over 79 occurrences. Missed occurrences after downtime collapse to one fire (`schedule_domain.ml:683-690`, next due computed past `now`). Re-dispatch after a crash is idempotent by occurrence id (`Keeper_wake_already_acked/failed/cancelled`, `server_bootstrap_maintenance.ml:93-101`). The 3 `due` rows (held 3.0-6.4 h) target paused Keepers rondo and ocaml-agent-ic: bounded at one pending occurrence each, by design.
- **Goal happy path**: Executing -> Verifying -> (verifier proof) Awaiting_confirmation -> operator confirm (`/api/v1/goals/confirmation`, CanAdmin, `server_routes_http_routes_verification.ml:190-201`) -> Candle `after_confirmation` -> Completed ran once this week (goal-keeper-automation: proof 10-04 13:31Z, confirm 10-05 05:05Z). Goal creation requires metric and target (`goal_store.ml:1056-1059`); blank title and past due are #41399 (open, not merged).

### Baseline addendum: D6-08 measured
- Still open and now costs every boot: `verification_run_registry: skipped 19 malformed replay line(s); first=…verification-runs.jsonl:5: unknown verification outcome "operator_routed"` logged 13 times on 10-06 (one per boot). `run_registry_core.ml:808-812` compacts only when `snapshot.malformed = []`, so the ledger has not been compacted since 09-25: 2,996 runs, 18 MB, fully replayed at each of 13 boots on 10-06. Fix is the operator `cut-run-registries` step already written in 10-01 D6-08. One run (`vrf-b2a7564da888…`, task-2172, 10-06 19:46Z) is registered with no completion — consistent with a restart mid-review; it is dropped as `dropped_running` on replay.

## 4. Feature matrix

| Feature | Happy path | Edge cases | Observability | Verdict | Evidence |
|---|---|---|---|---|---|
| Goal create/update | metric+target required; unreadable due refused | blank title / past due accepted (#41399 open); upsert last-writer-wins, no CAS | goal_events.jsonl ~2/day | Partial | `goal_store.ml:815-826,1056-1073` |
| Goal FSM | exhaustive matrix incl. Pause/Block (#41151) | second writer for ->Verifying (F-07) | phase events | OK | `goal_phase.ml:104-172`, `workspace_goals.ml:705-713` |
| Goal verification | ran once (10-04 commit) | 900 s per failed attempt, retired model retried 15x, any wake rescans all Verifying (D7-02) | run ledger has only last candidate's error | Partial | F-02, `goal_verification_agent.ml:118-145,687-716` |
| Goal confirm -> Candle | CanAdmin route -> `Candle_payout_owed.after_confirmation` inside goal lock | Candle write failure refuses the confirmation | Candle WARN when Disabled | OK (Candle On since 10-06, no pass with Snapshot yet) | `workspace_goals.ml:1089-1123`, `candle_payout_owed.ml:33-55` |
| Goal notices | outbox -> fleet passive broadcast | stuck 34.5 h 10-04..06, fixed #41237 | WARN per minute per recipient | OK now | F-01 |
| Goal overdue | TUI colours overdue | no notice since #39975; 3 overdue Executing Goals unreviewed | TUI only | Partial | F-04 |
| Task FSM | exhaustive `decide`, verdict path | operator reset outside `decide` (guarded) | broadcast per transition | OK | `workspace_task_lifecycle.ml:58-270` |
| Task verification | 10-06 69 verdicts, 0 not_reviewed | 10-03 0 verdicts; 68.6 slot-h wasted 10-04; image evidence not refused at submit (D6-09) | run ledger | Partial | F-02 addendum |
| Task GC / archive | archive-first (#40427/#40571) | never scheduled; last run 09-20; 95% of backlog bytes terminal | none | Partial | F-06 |
| HITL approval queue | durable, replays at boot, split preserved behaviour | Manual/Auto-judge never run live (`always_allow` since 09-23) | install report | Unknown live / OK code | `gate/mode.json`, split check |
| Chat-hook approval | 180 s wait, 900 s late memory | in-memory, lost on restart (by design) | - | OK | `keeper_late_approval.ml:43-58` |
| Schedule fire/hold | 570/day, 0 failed (10-06) | paused target holds forever (bounded 1); missed collapse to 1 | dispatch/hold lines | OK | `schedule_domain.ml:683-690` |
| Schedule edit (TUI/dashboard) | edits save | erases `result_delivery` (D5-10) | none | Broken (edge) | F-03 |
| Schedule ledger size | - | 4.1 MB, 53 live of 655, notes 56% | - | Partial | F-05 |

## 5. Context / token / cache waste

- Verifier attempts with no verdict: 15.8 / 26.2 / 68.6 / 38.1 slot-hours on 10-02..10-05 (sum of `elapsed_s`, `verification-runs.jsonl`), plus 19 x ~900 s for one Goal (`goal-verification-runs.jsonl`). Token counts are not in either ledger, so the spend in tokens is unknown; the attempts carried the full review prompt each time.
- Goal notice fan-out: each notice is appended to every Keeper transcript (28 on 10-05). Goal events are ~2/day, so this is small in steady state; it was 28 failing appends per minute for 34 h during F-01.
- Active Goals prompt layer is limited to Goals linked to the Keeper's current Task (`keeper_unified_prompt.ml:1291-1321`): bounded, no waste found.
- Disk I/O (not tokens): `schedules.json`+`.last-good` 8.2 MB per change, `backlog.json`+`.last-good` 8.4 MB per Task transition, 18 MB verification ledger replayed per boot (13 boots on 10-06).

## 6. Coupling

- Goal -> Candle: confirmation runs the Candle `Payout_owed` write inside the Goal lock (`workspace_goals.ml:1110-1112`); a Candle ledger failure blocks Goal completion. Separable: write the owed row as a Goal outbox effect after commit (the outbox already exists for notices, `goal_delivery.ml`).
- Goal/Task verification -> Domain A exact lanes: verdict throughput is entirely lane health (rest records, retired-model classification). Necessary; the missing piece is in Domain A.
- Goal notices -> Broadcast/keeper chat store (fleet snapshot, `Deferred_passive_fleet`). Necessary; F-01 showed a store-level threading bug can block it for a day.
- Schedule -> Keeper event queue, Keeper paused flag, continuation channel (`server_schedule_consumers.ml`). Necessary.
- HITL queue -> Keeper meta, event queue and operation store (delivery retirement reads all three, `keeper_approval_queue.mli` install doc). Necessary for retirement; wide.
- Candle keeps its own `task_status` projection with an exhaustive mapping (`candle/candle_event.ml:3-9`, `candle_runtime/candle_tasks.ml:78-86`): deliberate ledger shape, not a duplicate concept.

## 7. Tracking (gh search 2026-10-07)
- F-01: fixed by #41237.
- F-02: related open issue #40994 (verifier retry causality; #40997 and #41003 merged against it on 10-04, issue still open). Retired-model-as-permanent-refusal not named as its own item; belongs with Domain A classifier work (#38061 covers lane-walk rules, not this).
- F-03 (D5-10): untracked.
- F-04: related open issue #39571 (overdue Goal looks like one in progress).
- F-05 (D5-02/D5-07), F-06 (D6-11 schedule half), D6-08: untracked as PR/issue; recorded only in the 10-01 audit.
- F-07: untracked (P3).
