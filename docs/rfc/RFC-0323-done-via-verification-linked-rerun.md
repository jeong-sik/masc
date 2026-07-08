# RFC-0323 — Done via verification + linked re-run tasks (retire Done-reclaim)

- Status: Draft (v2.1 — goal matrix + radius census)
- Decision driver: operator (2026-07-08) — "승인-반려 스텝을 안 거친 것은 Done이 되면 안 된다. 반려되면 안 하든가, 승인되면 하든가. 다시 하려면 태스크를 만들고 연관으로 걸어라."
- Area: `lib/workspace/workspace_task_lifecycle.ml` (`decide`, `resolve_claim`), `lib/types/types_core.ml` (`task` record, `task_claim_decision`), `lib/task/tool_task*.ml` (tool surface + schema text), `lib/workspace/workspace_task_create.ml`, completion side-effect sites (`workspace_task_transitions.ml`, `activity_graph*`), read models (`lib/dashboard`, `lib/keeper` observation).
- Builds on / supersedes:
  - **Implements RFC-0308** (verification-required done guard — dead scaffold today: error variant `Verification_required_use_submit` at `workspace_task_lifecycle.ml:9` and seam `task_requires_verification` at `tool_task_contract_gate.ml:26-29`, both zero producers/callers).
  - **Supersedes the Done-reclaim mechanism of #23632** (merged `6bbcecf52f`) including the interim same-actor guard (`workspace_task_lifecycle.ml:74-92`, labeled `removal target: RFC-0323 merge`). **Narrowed**: #23632's `claim_next` eligible-match restructure (`workspace_task_schedule.ml:430-445`) is NOT superseded — it fixes AwaitingVerification-only-backlog verifier claiming (RFC-0220 §3.5) and must be kept.
  - Complements RFC-0311 (evidence gate — already covers both `Done_action` and `Submit_for_verification`, `tool_task.ml:446-457`), RFC-0220/0221 (verification FSM/atomicity), RFC-0267 (goal linkage), RFC-0314 (recurrence), RFC-0199 (deterministic probe — disposition changes here, see G-2).
- Evidence base: two censuses 2026-07-08 — 4-scout domain census (203 tool uses) + 6-axis radius census (339 tool uses) at HEAD `b919bd0a9a`; file:line cited inline. Load-bearing claims (approve-arm authority-blindness, probe identity, done-hook gating) independently re-read before this revision.

## Problem (audited)

Fake completions are structural, not accidental. The FSM has two completion lanes and the weak one is cheaper:

- **Weak lane (always legal)**: `(Claimed|InProgress, Done_action)` by the owner — `workspace_task_lifecycle.ml:166-177`. Tool-layer gates exist (RFC-0311 evidence refs, LLM review) but no second agent ever looks at the work, and the RFC-0199 deterministic probe (`keeper_tool_task_runtime.ml:598-634` → `force_done_task_r`, System authority) bypasses every tool-layer gate — and swallows its own errors (`:632-634`).
- **Strong lane (optional)**: `Submit_for_verification` (non-empty notes required, `workspace_task_transitions.ml:241-247`) → advisory verifier binding (self-block #19314, `workspace_task_lifecycle.ml:133-150`) → `Approve_verification → Done` / `Reject_verification → InProgress{assignee}` (`workspace_task_lifecycle.ml:227-259`).
- The tool schema actively teaches the weak lane: "Tasks created through masc_add_task complete via action='done' … they do not route normal completion through the verifier agent" (`tool_task_schemas.ml:220-233`).

#23632 (task-1869) responded to the *symptom* — completed coordination tasks that need to run again — by making `Done + Allow_reclaim` claimable in place. That (a) weakens what `Done` means, (b) required a same-actor livelock guard, and (c) is **unreachable in production**: creation defaults `reclaim_policy = None` (`workspace_task_create.ml:181,303`), the only `Allow_reclaim` writer is the supervisor pause policy feeding `Release → Todo` (`keeper_supervisor_pause_policy.ml:52,75`), and every claim wipes the reclaim fields (`workspace_task_claim.ml:16-21`).

## Decision

1. **Done is reached only through the verification lane.** `Done_action` on a verification-required task returns `Verification_required_use_submit` (the RFC-0308 error that already exists). Approve → `Done`; Reject → `InProgress{assignee}` (already implemented; unchanged).
2. **A verified Done is terminal for every actor.** No reclaim-on-Done. To run the work again, **create a new task linked to the completed predecessor** (`predecessor_task_id`), or (later) an RFC-0314 recurrence variant that creates new task instances.
3. **Retire the #23632 Done-reclaim mechanism** (both the `task_claim_decision` Done arm and the `resolve_claim` Done arm, including the interim same-actor guard) — but keep the `claim_next` eligible-match restructure.
4. **Completion side effects key off the resulting `Done` state, not the `Done_action` that produced it.** Today economy/hebbian hooks, `task.done` activity events, span completion, and `duration_ms` all fire only on `Done_action` — a verification-lane fleet would silently lose all of them (G-3).

## Ordering constraints (hard)

| Constraint | Why |
|---|---|
| **G-2 before G-1** | The RFC-0199 probe force-dones contracted tasks under the keeper's *own* identity (`keeper_tool_task_runtime.ml:630`, `~agent_name:(keeper_agent_sender ~meta)`) and swallows errors (`:632-634`). G-1 guards exactly the contracted set → landing G-1 first silently kills the probe. |
| **G-8 before G-10** | Retiring Done-reclaim restores the pre-#23632 dead-end (`AlreadyClaimed by <completer>`, `workspace_task_claim.ml:176`) for re-run attempts. The successor-task path must exist first, and G-10 REPLACES the claim-on-Done error to point at it. |
| **G-3, G-4, G-6 before G-5** | Phase B flip is gated on side-effect parity, teaching-surface flip, and read-model semantics (readiness gates below). |

## Goal Matrix

One goal = one PR. Radius = files actually modified; Boundary = adjacent-and-explicitly-untouched.

| G | WS | Deliverable | Radius (touch) | Boundary (do-not-touch) | Deps | Verification |
|---|---|---|---|---|---|---|
| G-0 | doc | This RFC + matrix (#23659) | `docs/rfc/` | — | — | review + merge |
| G-1 | W1-A | RFC-0308 guard producer (contracted tasks) | `workspace_task_lifecycle.ml{,i}` (new `~requires_verification` param; Done arms `:166-173` → `Verification_required_use_submit`; `valid_next_actions` `:277-304` threads it), `workspace_task_transitions.ml:128` (compute from task record), predicate hosted in types/workspace layer (see G-1 note), `workspace_task_classify.ml:365-372` hints, tests | schema text (G-4), probe (G-2), evidence gate, Phase B default | G-2 | contracted task + `Done_action` → `Verification_required_use_submit`; uncontracted unchanged; hints list `submit` not `done` for contracted |
| G-2 | W1 | RFC-0199 probe disposition (**lands first**) | `keeper_tool_task_runtime.ml:598-634`, machine-verifier identity constant, probe tests (`test_keeper_deterministic_evidence_probe.ml`, `test_deterministic_evidence_evaluator.ml`) | approve-arm semantics, guard itself | — | probe completes a contracted task through submit→approve; no self-approval violation; failure not swallowed silently |
| G-3 | W1 | Completion side-effect parity (state-keyed, not action-keyed) | `workspace_task_transitions.ml:623-651` (duration_ms + `run_done_hooks` on approve; assignee from `Done` record — actor on Approve is the *verifier*), `activity_graph_reducer.ml:212` (+`task.approved` arm or emit `task.done`), `activity_graph.ml:644-651` (span end), tests | FSM arms; `event_kind.ml` closed enum (teach reducer instead of new kind) | — | approve-completion produces economy earn + closed span + nonzero duration + graph deactivation |
| G-4 | W1 | Teaching/affordance surface flip | `tool_task_schemas.ml:220-233` (+`:34,:255,:260`), `mcp_server.ml:423` doc table, remediation strings `workspace_task_transitions.ml:187-189,:213-215`, `keeper_agent_tool_surface.ml:141-146` (Task_verify prefers `keeper_task_done` which hardcodes `action="done"` `keeper_tool_task_runtime.ml:831-834` — cannot clear pending_verification; wasted verify turns) | FSM logic; tool dispatch | G-1 | schema/hints describe submit→approve as the completion path; verify-turn preferred tools can actually approve |
| G-5 | W1-B | Default-on flip + readiness gates | default predicate (distinct from contract seam) + Phase-B test set | everything else (flip is one default change) | G-1..4, G-6 | readiness gates below all green |
| G-6 | W1 | AwaitingVerification-as-normal read models | `dashboard_goals_types_builder.ml:344-352,:472-479,:506-507` (`direct_fsm_risk` → at_risk inversion), `dashboard_briefing_assembly.ml:285-289` ("paused"), `server_dashboard_http.ml:588-595` rollup class, `keeper_runtime_contract.ml:137-144` blocked-detector | FE kanban/board components (already render awaiting) | — | goals with awaiting tasks are not flagged at-risk/paused under the verification lane |
| G-7 | hygiene | Latent bypass + stale docs | delete `Task_dispatch.update_status` (`task_dispatch.ml:115-152`, zero production callers, writes any status incl. Done with no decide/gates) or wire through decide; fix stale "Default: false" comment `env_config_runtime.ml:300` | `Task_dispatch.delete_task` (has callers) | — | no status-write path outside `decide` remains reachable |
| G-8 | W2 | `predecessor_task_id` core | `types_core.ml{,i}` record `:587-601` + codec `:695,:743` (omit-when-None per `created_by` pattern `:705-707`; malformed value degrades to `None` — decode `Error` would silently DROP the task via `backlog_of_yojson` `:922-924`), `workspace_task_create.ml{,i}` (arg, two literals `:169-184,:291-306`, existence + terminal validation via `task_status_is_terminal` `:370-372`), `tool_task_handlers.ml` (`valid_keys` `:266` — mandatory or arg is rejected; Unknown_goal pattern `:302-316`), `tool_task_schemas.ml:69-72`, tests (codec round-trip, unknown-id, non-terminal predecessor) + 17 test files with full task literals (compiler-forced) | batch add (positional 5-tuple — widen later if needed), `keeper_task_create` (None default correct), goal registry (RFC-0267: many-to-many mutable side registry ≠ write-once lineage pointer) | — | round-trip with/without field; old backlog decodes; unknown/non-terminal predecessor → typed error |
| G-9 | W2 | Predecessor surfacing (display) | `server_dashboard_http_core_entities.ml:29-50` (hand-rolled 7-field subset), `dashboard/src/types/core.ts:52`, task-detail lineage (`task-detail-state.ts:65-126` scaffolding exists) | rich `task_json` (`dashboard_execution.ml:555-579` auto-inherits from codec) | G-8 | task detail shows predecessor link |
| G-10 | W3 | Retire Done-reclaim (hunk-verdict table below) | `types_core.ml:653-666` REVERT; `workspace_task_lifecycle.ml{,i}` `Blocked_by_reclaim_policy` variant `:57-58` + Done arm + interim guard `:74-92` REVERT; `workspace_task_claim.ml:161-174` REVERT plumbing but **REPLACE** error with terminal + successor-task hint; tests per table | `workspace_task_schedule.ml:430-445` **KEEP** (RFC-0220 §3.5 fix); reclaim-field data plumbing (below) | G-8 | `Done` never claimable for any (policy, actor); claim-on-Done error names the successor path; `reclaim_policy` enforcement-retirement decision recorded (post-#23661 it has zero `task_claim_decision` readers once the Done arm reverts) |

### G-1 layering note

`decide` is pure and receives only `~task_status` (`workspace_task_lifecycle.ml:109-122`) — the guard needs a `~requires_verification` parameter threaded from `transitions.ml:128` where the task record is in scope. The predicate currently lives in `lib/task/tool_task_contract_gate.ml:21-29`, but `lib/workspace` must not depend on `lib/task` (reverse dependency). Host the predicate beside the contract type (types/workspace layer); `tool_task_contract_gate.task_requires_verification` becomes a re-export.

### G-2 corrected options (census refutation)

v2 proposed "probe becomes submit + System-actor approve (System ≠ assignee, so the self-approval check holds)". **This is wrong on current code**: the Approve arm never reads `~authority` — it checks only `same_agent assignee` (`workspace_task_lifecycle.ml:229-230`), and the probe runs under the keeper's own identity, which IS the assignee. System is an authority, not an identity; authority cannot unlock self-approval. Corrected options:

- **(i) recommended — submit + machine-verifier approve under a distinct identity.** Probe submits as the keeper (assignee submits: legal, `workspace_task_lifecycle.ml:206-221`; probe already has non-empty notes), then approves under a namespaced machine identity (e.g. `probe:deterministic`, following the `operator:<actor>` precedent, `server_routes_http_routes_verification.ml:41-43`) — identity keys differ, self-approval check holds, typed `evidence_claims` remain the real evidence. **Store-record decision (resolved in G-2 review, #23665)**: the wrapper mirrors the tool layer's RFC-0221 hooks — record created with the submit (compensating delete if the commit fails), machine verdict recorded on approve or on the compensating reject, and on a double failure the Pending record is deliberately left actionable so the stranded task stays inside the pending-verification wake join and the dashboard verification panel (recovery through the normal lane, no bespoke stranded metric — counter-as-alarm rejected). Board/SSE notify hooks are not invoked; machine completions do not announce.
- **(ii) demote to advisory**: probe posts evidence, a real verifier approves. Loses automation.
- **(iii) rejected — authority exemption in the guard**: reintroduces a non-verification Done lane; violates Decision 1.

Also: replace the silent `Error _ -> ()` swallow (`keeper_tool_task_runtime.ml:632-634`) with a logged/typed outcome while in there.

### G-5 readiness gates (Phase B flip preconditions)

1. No `MASC_VERIFICATION_FSM_ENABLED=false` override in the running environment (registry default is already true, `feature_flag_registry.ml:221-224`; a false override turns every submit/approve into `Verification_disabled`).
2. **Every room with a submit-capable keeper has ≥2 distinct approve-capable identities** (structural anti-starvation: submitter cannot self-claim `:144-146`, self-approve `:229-230`, Release `:200-202`, or Cancel `:186-190`; the timeout sweep is a deliberate no-op `verification_protocol.ml:391-394` — a solo room wake-loops forever on its own submit).
3. Cross-store join integrity: zero AwaitingVerification tasks without an actionable verification-store record (wake requires the join, `keeper_world_observation_inputs.ml:35-44`; a lost record = starvation *without* the wake signal).
4. G-4 landed: verify-turn preferred tools can approve; schema no longer teaches direct done.
5. G-6 landed: goals with awaiting tasks not flagged at-risk/paused.
6. Starvation disposition recorded: RFC-0220's neutered timeout stays neutered (deliberate); the backstop is structural (gate 2), not a timer.

### G-10 hunk-verdict table (#23632 = `6bbcecf52f`, squash; `8fce078b2c` folded in)

| file:line (main) | Hunk | Verdict |
|---|---|---|
| `types_core.ml:653-666` | Done reclaim arm | REVERT → unconditional `Claim_unavailable (Claim_block_not_todo …)` |
| `types_core.ml:607-611` | block-reason helper | DELETE — dead since #23661 (`27e2f4230c`) removed the Todo gate; its last remaining reader is the Done arm this table reverts |
| `workspace_task_lifecycle.ml:57-58,:74-92` + mli | `Blocked_by_reclaim_policy` variant + Done arm + same-actor guard | REVERT → `Done { assignee; _ } -> Held_by_other assignee` |
| `workspace_task_claim.ml:151,:161-174` | task-typed call + Blocked plumbing | REVERT; **REPLACE** the resulting `AlreadyClaimed` UX with a terminal-status error naming the `predecessor_task_id` successor path |
| `workspace_task_schedule.ml:302-313,:354,:485` | blocked_reclaim scan + Blocked arms | arms REVERT with variant; scan: after #23661 no Todo producer remains and G-10 removes the Done producer → `Claim_block_reclaim_policy` becomes unproducible; simplify or remove the scan in G-10 |
| `workspace_task_schedule.ml:430-445` | eligible-match restructure | **KEEP — not superseded** (fixes AwaitingVerification-only-backlog verifier claim, RFC-0220 §3.5) |
| `test_workspace_task_lifecycle.ml:428-454` | Done-arm cases | `:428-433` KEEP; `:434-439,:449-454` REPLACE with "Done is terminal" pins; `:440-448` (self-livelock) DELETE |
| `test_workspace_coverage.ml:732,:759,:1945` | reclaim-success/blocked-count tests | REPLACE (not claimable / Error / blocked_count 1→0) |
| `test_workspace_coverage.ml:1928,:404-412,:704-730` | terminal-default test, fixtures, helpers | KEEP |
| `workspace_task_lifecycle.ml:132` (`Claim, Done _ -> ok`) | pre-existing idempotent no-op | KEEP (retry idempotency), recorded as accepted inconsistency |

## Radius Map (adjacent systems — 경계 선언)

| Adjacent system | Disposition | Reason (file:line) |
|---|---|---|
| RFC-0311 evidence gate | UNTOUCHED | already gates both `Submit_for_verification` and `Done_action` (`tool_task.ml:446-457`); W1 reroute stays inside coverage |
| RFC-0221 submit compensation | INTERFACE-ONLY | more traffic through the submit arm (`tool_task.ml:537-544`); logic unchanged |
| RFC-0199 probe | MODIFIED (G-2) | see corrected options |
| RFC-0314 recurrence | UNTOUCHED | Broadcast-only today (`keeper_recurring.ml:9-10`); a future task-creating variant calls `add_task_with_result` where G-8's arg already lives — integration is free later |
| RFC-0267 goal registry | UNTOUCHED | goal→tasks many-to-many mutable side registry (`workspace_goal_index.mli:17-29`) ≠ task→task write-once lineage pointer |
| RFC-0220 neutered timeout | UNTOUCHED | deliberate (`verification_protocol.ml:380-394`); backstop is structural (G-5 gate 2) |
| Event/SSE kinds | UNTOUCHED | `task.submit_for_verification/approved/rejected` already exist and are emitted (`event_kind.ml:15-24`, `transitions.ml:607-621`); G-3 teaches the reducer instead of adding kinds |
| Reclaim-field data plumbing | UNTOUCHED (G-10 boundary) | supervisor pause `Allow_reclaim` handoff (`keeper_supervisor_pause_policy.ml:52,75`), release derive (`workspace_task_claim.ml:330-363`), cancel preserve (`workspace_task.ml:113-117`), `clear_reclaim_decision` (`:16-21`), telemetry classifier (`task_transition_state.ml:260-261`), release schema enum (`tool_task_schemas.ml:291-295`). NOTE: since #23661 removed the Todo claim gate, these writers feed fields with **no remaining `task_claim_decision` enforcement** once G-10 reverts the Done arm — the fields become inert data. Full retirement of `reclaim_policy` (and the RFC-0034 anti-oscillation question its release hard-stop used to answer) is a recorded follow-up decision, not silently expanded G-10 scope |
| Claimable filters | UNTOUCHED | dashboard (`work.ts:214-216`) and keeper observation (`keeper_world_observation_inputs.ml:53-67`) are Todo-first — Done-reclaim was invisible to both in *both* directions |
| Benchmark harness | UNTOUCHED | zero task-status reads (`keeper_benchmark_canary.ml`, `repo_synthesis_benchmark.ml`) |
| RFC-0304 keeper HITL queue / RFC-0321/0322 / board claim gate | UNTOUCHED | different domains, no shared files |
| Verification-lane gaps 1–4 (below) | FOLLOW-UP | confirmed present on main; separate RFCs/issues |

## In-flight collisions (2026-07-08)

| PR | Files | Collides with | Action |
|---|---|---|---|
| #23661 (`albini/task-1869-clean`) | `types_core.ml` only | G-8/G-10 (same file, same mechanism) | **MERGED (`27e2f4230c`) post-redirect** — removed the Todo `Block_reclaim` gate entirely. Its in-code comment asserts "reclaim_policy only gates Done → re-claim", which inverts the census finding (the Todo release hard-stop was the only production-reachable use; Done-reclaim is the dead mechanism G-10 retires). Consequence: post-G-10 `reclaim_policy` has zero decision readers — see Radius Map note |
| #23641 (`garnet/task-1869`) | `workspace_task.ml`, `transition_executor.ml` | G-10 | redirect — reclaim_policy semantics under retirement |
| #23640 (`nick0cave/task-1869-claimable-staleness`) | `keeper_runtime_contract.*` | G-6/G-10 (MEDIUM) | review against matrix |
| #23626 (`rondo/task-1862-add-recurring`) | tool schemas/dispatch/registry | G-8 (MEDIUM, file-level) | merge-order coordination |
| #23589 (evidence-gate retire) | gate routing + shared tests | G-1/G-2 (MEDIUM) | merge-order coordination |

Three parallel task-1869 PRs were iterating on exactly the mechanism G-10 retires; #23640 and #23661 have since merged (2026-07-08). #23661's semantics inversion is absorbed above rather than relitigated — G-10 implements against current main.

## Invariants (end state)

- `Done` is producible only by `Approve_verification` (G-2 disposition included — probe approval is an approve under a distinct machine identity, not a bypass). No status other than `AwaitingVerification` transitions to `Done`.
- `Reject_verification → InProgress{assignee}` — rejected work is not done and returns to the submitter (already implemented, unchanged).
- Terminal tasks are never re-claimed; re-running work creates a new task with `predecessor_task_id` provenance; `predecessor_task_id` is write-once and its referent must be terminal at link time.
- Verifier ≠ assignee (existing #19314 identity-normalized block).
- Completion side effects (economy, activity graph, duration, hooks) fire for every transition that *produces* `Done`, regardless of action (G-3).

## Out of scope (recorded, separate follow-ups — all re-confirmed on main)

Verification-lane gaps that matter for Phase B integrity but are not fixed here:
- Verifier binding is advisory — approve arm discards the phase (`workspace_task_lifecycle.ml:227-228` matches `_`); any non-submitter can approve even when another verifier is bound.
- Approve accepts empty notes (`:243`, formatting-only), asymmetric with submit; approve-side contract gate is a typed no-op seam (`tool_task_contract_gate.ml:71-79`).
- Dashboard operator verdicts run as `operator:<actor>` (`server_routes_http_routes_verification.ml:41-43`) — a namespace that never equals an assignee identity key, sidestepping the self-approval check for a human who also drives an assignee keeper. G-2 adds a second namespaced machine identity (`probe:deterministic`), making this a family: **namespaced identities live outside the agent registry and distinctness rests on `task_identity_key` string comparison**. The follow-up should reserve/type the namespaces (reject `operator:`/`probe:` prefixes at agent join, typed namespace registry) rather than grow per-caller enums.
- Verification timeout sweep is a deliberate no-op (`verification_protocol.ml:391-394`, RFC-0220 §5) while its fiber still burns 60s cycles (`server_bootstrap_loops.ml:782-789`).
- `pending_verification` wake has no goal-scope filter and no self-exclusion (`keeper_world_observation_inputs.ml:80-86`) — solo-room submitters wake themselves fruitlessly (mitigated structurally by G-5 gate 2).
