# Keeper caution 24h audit - 2026-06-26

status: in_progress
last_verified: 2026-06-27T07:46:18+09:00
runtime_window_utc: 2026-06-25T06:31:00Z..2026-06-26T06:31:00Z
runtime_root: `<RUNTIME_ROOT>`
repo_head: `origin/main` at worktree creation

## Evidence

- [근거] Live health: `curl -fsS '<MASC_HTTP_BASE>/health?full=1'`, checked 2026-06-26T15:31+09:00, confidence High. Runtime reported version `0.19.48`, commit `e882945c06d`, effective base path `<MASC_BASE_PATH>`, effective root `<RUNTIME_ROOT>`, `keeper_identity_drift.status=degraded`, `logs.recent_warnings=17`.
- [근거] 24h log aggregation: parsed `<RUNTIME_ROOT>/logs/system_log_2026-06-25.jsonl` and `system_log_2026-06-26.jsonl` with cutoff `2026-06-25T06:31:00Z`, checked 2026-06-26T15:37+09:00, confidence High.
- [근거] 24h receipt aggregation: parsed `<RUNTIME_ROOT>/keepers/*/execution-receipts/2026-06/{25,26}.jsonl`, checked 2026-06-26T15:38+09:00, confidence High.
- [근거] Current code overlap: `git log e882945c06d..origin/main -- lib/keeper/keeper_meta_json.ml config/prompts lib/keeper/keeper_prompt_token_integrity.ml`, checked 2026-06-26T15:34+09:00, confidence High.
- [근거] OCaml/Eio design basis: OCaml 5.4 manual parallelism/memory-model docs and Eio Switch documentation, checked 2026-06-26T15:33+09:00, confidence Medium because exact downstream version behavior still needs CI.

## Refresh - 2026-06-27 07:46 KST

Evidence refresh:

- [근거] Live health: `curl -fsS '<MASC_HTTP_BASE>/health?full=1'`, checked 2026-06-27T07:39+09:00, confidence High. Runtime reported version `0.19.50`, commit `3ae98cf2293`, `paths.effective_base_path=/Users/dancer/me`, `paths.effective_masc_root=/Users/dancer/me/.masc`, `keeper_fleet_safety.status=blocked`, `keeper_identity_drift.status=degraded`, and `keeper_reaction_ledger.status=degraded`.
- [근거] 24h decision-log error aggregation: parsed `<RUNTIME_ROOT>/keepers/*.decisions.jsonl` with `cutoff=$(date -u -v-24H +%s)`, checked 2026-06-27T07:42+09:00, confidence High.
- [근거] Current code remediation: focused `scripts/dune-local.sh exec ./test/test_keeper_turn_driver_accept.exe`, checked 2026-06-27T07:45+09:00, confidence High for the touched finalization boundary only. Full build authority remains PR CI.

Current live caution list:

1. P0 fleet safety blocked: no executable keeper fibers
   - Current health: `keeper_fleet_safety.status=blocked`, `blocker=no_executable_keeper_fibers`, `bootable_keeper_count=0`, `running_keeper_fiber_count=0`.
   - Direct reasons: five autoboot-enabled keepers are durably paused: `albini`, `idealist`, `mad-improver`, `nick0cave`, `verifier`.
   - Operator action in health: `resume_or_leave_paused`.

2. P0 repeated no-text completion failures
   - Count in current 24h decision logs: `nick0cave=66`.
   - Terminal reason: `internal_error`, next action `inspect_latest_error`.
   - Error text: `Internal error: keeper turn completed with no textual reply`.
   - Root implementation gap: the finalization safety net converted blank text/no tool progress into `Agent_sdk.Error.Internal`, losing the existing typed accept-rejection/no-progress path.

3. P0 no-progress-loop pauses
   - Current paused metadata: `mad-improver` and `sangsu` have `last_blocker.klass=no_progress_loop` with `streak=10 threshold=10; manual pause applied`.
   - Risk: manual pause is correct as a stopgap, but the system must not turn this into prompt constraint stacking or a fleet-wide stop. The blocker must remain per keeper.

4. P1 identity drift
   - Current health: `keeper_identity_drift.status=degraded`, terminal reason `configured_keeper_without_runtime_meta`.
   - Direct item: configured keeper `analyst` has no persisted runtime meta.
   - Next action from health: `materialize_configured_keeper_or_disable_unused_toml`.

5. P1 reaction ledger pending stimulus
   - Current health: `keeper_reaction_ledger.status=degraded`, `pending_stimulus_count=1`.
   - Direct item: keeper `sangsu`, pending `stimulus:21b111835489d00fe0002928f5c49b89`.
   - Risk: a paused keeper with pending stimulus keeps the fleet in caution unless the pending ledger state is resolved or explicitly quarantined.

6. P1 singleton provider/runtime errors
   - Current 24h decision-log aggregation:
     - `verifier`: one `provider_error_timeout:http_operation`, next action `inspect_latest_error`.
     - `idealist`: one typed `accept_rejected` with `reason_kind=no_usable_progress`, `response_shape=thinking_only`.
   - These are not the dominant current error volume, but they prove the typed no-progress path already exists and should be reused instead of adding another string classifier.

7. P2 tool invocation shape errors
   - Current 24h decision-log aggregation: one `executor` and one `idealist` `tool_exec` record where `Execute` arguments did not include exactly one of `executable | pipeline`.
   - Risk: this is a deterministic tool-shape contract issue, not a reason to weaken shell/path guards.

Hardening slice 2 started:

- Changed `lib/keeper/keeper_agent_run.ml` so blank response finalization reuses `Keeper_turn_driver_try_provider.accept_rejected_error` instead of emitting a generic internal error.
- Exposed the helper through `Keeper_agent_run.For_testing` in `lib/keeper/keeper_agent_run.mli`.
- Added `test_finalization_blank_response_is_typed_accept_rejection` in `test/test_keeper_turn_driver_accept.ml`.

Adversarial checks for slice 2:

- No local path hardcoding added.
- No new environment variable or runtime knob added.
- No free-form error-string classifier added; the patch reuses the existing typed accept-rejection and OAS response-shape diagnostics.
- No new global keeper/fleet gate added; the outcome remains per turn and per keeper.
- No new mutex, lazy value, blocking I/O, or Eio resource lifecycle path added.
- Failure remains explicit: blank/no-tool output now returns a typed `Accept_rejected` error, so it can be counted by the existing completion-contract auto-pause path.

## 24h Caution Inventory

1. P0 alert flood: `stale_keeper_broadcast`
   - Count: 4445 total.
   - Top keepers: `taskmaster=732`, `executor=690`, `sangsu=465`, `idealist=428`, `issue_king=426`, `garnet=387`, `ramarama=365`, `albini=256`, `mad-improver=242`, `nick0cave=198`, `verifier=189`, `rondo=67`.
   - Evidence example: `garnet: stale_keeper_broadcast emitted last_turn=<N>s ago runtime=ollama_cloud.deepseek-v4-pro`.
   - Immediate repeated-emission mechanism: `emit_stale_keeper_broadcast` emitted every watchdog sweep with no durable state saying the same stale identity was already broadcast.
   - WORKAROUND: production-blocking alert flood mitigation while state-backed broadcast idempotence is designed.
   - Follow-up: issue #22391 tracks the root state-machine fix for durable broadcasted-state linkage across stale watchdog and receipt-side repeats.
   - Removal target: replace this in-memory stale-watchdog mitigation when #22391 lands.
   - Started mitigation: `lib/keeper/keeper_execution_receipt.ml` now suppresses duplicate stale broadcasts in the same keeper/runtime/trace/generation/failure/stale-bucket while still emitting at bucket transitions or new failure identity.

2. P0 recovery stimulus loop: `no-progress-loop:*`
   - Count: 3148 consumed events.
   - Top keepers: `garnet=965`, `taskmaster=886`, `rondo=561`, `verifier=352`, `albini=216`, `sangsu=116`, `executor=28`, `issue_king=24`.
   - Evidence example: `turn entry: consumed stimulus stimulus_id=no-progress-loop:garnet urgency=immediate class=no_progress_recovery`.
   - Risk: a paused or no-progress keeper can keep consuming immediate recovery stimuli, which looks like work but does not prove recovery.
   - Follow-up: audit event-queue ack/tombstone semantics for `No_progress_recovery`; do not solve by adding more prompt constraints.

3. P0 passive-only completion contract pauses
   - Count: 324 recent receipts with `passive_only`, `completion_contract_unsatisfied`, `alert_exhausted`, or non-pass dispositions.
   - Top observed pattern: `idealist` repeatedly produced `receipt_done/completed/pause_human/completion_contract_unsatisfied/passive_only`.
   - Risk: Keepers can appear to complete turns while making no durable progress, then immediately re-enter pause/caution flow.
   - Follow-up: connect `passive_only` receipts to no-progress recovery queueing and task/goal scope before changing thresholds.

4. P1 live runtime/meta schema drift: `multimodal_policy`
   - Count: 13764 warnings: `keeper meta ... has unknown keys: multimodal_policy`.
   - Current-head overlap: current source already includes `multimodal_policy` in `keeper_meta_json.ml` canonical fields, so this is likely live binary lag from runtime commit `e882945c06d`.
   - Follow-up: after CI/deploy, re-run `/health?full=1` and log aggregation; do not add another compatibility shim unless the warning survives current head.

5. P1 prompt token drift: `masc_web_*`
   - Count: 934 `unknown masc token "masc_web_*"` plus 934 stripped-token warnings.
   - Current-head overlap: current history contains `fix(keeper): remove prompt wildcard tool token (#22370)`.
   - Follow-up: verify on deployed runtime. Treat remaining hits as stale binary evidence unless reproduced on current head.

6. P1 repeated operator broadcast required
   - Count: 319.
   - Top reasons: `idealist pause_human completion_contract_unsatisfied=124`, `nick0cave pause_human internal_error=66`, `verifier pause_human completion_contract_unsatisfied=26`.
   - Risk: alert channel gets dominated by repeated symptoms instead of first actionable cause.
   - Started fix covers stale watchdog duplicates only. Receipt-side `completion_contract_unsatisfied` repeats remain deliberately unsuppressed until the no-progress/receipt linkage is fixed.

7. P1 stale active-goal snapshot clearing
   - Count: 537.
   - Top keepers: `idealist=257`, `verifier=88`, `garnet=41`, `executor=40`.
   - Evidence example: `keeper:idealist snapshot goal ... not in active_goal_ids, clearing`.
   - Risk: stale goal snapshots repeatedly churn prompt/runtime state and may bias keepers into passive inspection loops.

8. P2 path/tool execution misuse
   - Count: `shell_ir_path_not_found=13`, `execute_path_not_found=13`, `execute_command_shape_blocked=14`, `execute_gh_auth_missing=3`.
   - Evidence examples: missing `repos/poc-capability-negotiation`, missing `/tmp/.git-credentials`, missing `/home/keeper/.netrc`, shell pipeline encoded inside `argv`.
   - Risk: path drift is real, but current typed Shell IR guards are blocking deterministic bad shapes instead of silently executing them.
   - Follow-up: improve affordance/preflight messages and sandbox credential projection; avoid weakening path guards.

9. P2 session/auth/dashboard noise
   - Count: `SSE registration failed: unknown session=398`, dashboard token mismatch fallback `81`.
   - Risk: can obscure keeper-specific warnings in operator logs.
   - Follow-up: separate dashboard/session cleanup from Keeper no-progress fixes.

10. P2 memory librarian fallback
   - Count: `memory_librarian_fallback=197`, provider slot busy `81`.
   - Current-head overlap: current history contains memory fallback cadence/extraction work after runtime commit `e882945c06d`.
   - Follow-up: verify on current deployed runtime before adding new retry logic.

## Hardening Slice Started

Changed code:

- `lib/keeper/keeper_execution_receipt.ml`
- `lib/keeper/keeper_execution_receipt.mli`
- `test/test_keeper_receipt_authoritative.ml`

Design:

- Add typed stale-watchdog dedupe key from keeper, agent, runtime, trace, generation, failure cohort, terminal reason, stale kill class, and stale time bucket.
- Emit the first alert for each key.
- Suppress repeats in the same bucket with `OperatorBroadcastSuppressed` and INFO logging.
- Re-emit when the keeper moves into a later stale bucket or when trace/generation/failure identity changes.

Why this is not constraint hell:

- It does not add prompt instructions.
- It does not stop a keeper or the fleet.
- It does not use new environment variables.
- It does not hide first occurrence evidence.
- It does not string-match free-form error text; it uses existing typed failure-reason and terminal-code helpers.

## Adversarial Checks

- Hardcoded local path: committed evidence uses `<MASC_BASE_PATH>` and `<RUNTIME_ROOT>` placeholders instead of host/user-specific paths.
- Environment variables: no new `Sys.getenv*` or runtime env knob was introduced.
- Reimplementation: reused existing `OperatorBroadcastSuppressed`, `stale_turn_bucket`, `stale_broadcast_failure_cohort`, and `Keeper_turn_terminal_code` helpers.
- Fleet isolation: dedupe state is keyed per keeper; suppressing one keeper's duplicate stale alert does not block other keepers or new failure identities.
- Immutability/concurrency: the only mutable state is a small in-memory dedupe table protected by an `Eio.Mutex`; no I/O happens inside the critical section.

## Verification State

- `ocamlformat --inplace lib/keeper/keeper_execution_receipt.ml lib/keeper/keeper_execution_receipt.mli test/test_keeper_receipt_authoritative.ml`: passed.
- `scripts/dune-local.sh build test/test_keeper_receipt_authoritative.exe`: not run to completion. Wrapper refused because an existing bare `dune build .` process was active and bypassing the shared lock (`exit 75`). Per operator instruction, full build authority remains CI.
- Remaining required proof: draft PR CI on the focused test/quick suite.
