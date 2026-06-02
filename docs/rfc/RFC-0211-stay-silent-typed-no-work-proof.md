---
rfc: "0211"
title: "Stay-silent typed no-work proof (constraint-trap escape)"
status: Draft
created: 2026-06-02
updated: 2026-06-02
author: yousleepwhen
supersedes: []
superseded_by: null
related: ["0042", "0045"]
implementation_prs: []
---

# RFC-0211: Stay-silent typed no-work proof

## Problem

`keeper_stay_silent` is the keeper's decisive "no work for me this turn"
no-op. Two classifiers on the keeper turn path disagree about whether a
`keeper_stay_silent` call under an actionable signal satisfies the
required-tool contract, and the disagreement was **unconstructable** —
there was no input the model could supply to escape it.

Verified split-brain (2026-06-02, diagnostic w80pyf4eo):

1. **Satisfied.** `keeper_tool_progress.ml` lists `Stay_silent` in
   `completion_tool_names` (~line 75) and exempts it in
   `tool_name_can_satisfy_required_contract` (~line 142). The SDK
   completion-contract also accepts any tool call. So a stay_silent turn
   is "satisfied" on these paths.

2. **Violated.** When an actionable signal context is present,
   `actionable_tool_contract_violation_reason` (the arm at ~line 357)
   re-rejected stay_silent with the reason
   `"keeper_stay_silent without typed no-work proof"`.

3. **Unconstructable.** The "typed no-work proof" the violation demanded
   and the passive-loop nudge referenced
   (`keeper_passive_loop_detector.ml` nudge text) was never implemented.
   The `keeper_stay_silent` schema was the shared `empty_object_schema`
   (no properties; `agent_tool_descriptor.ml` "No arguments"), so there
   was no field the model could set to prove no-work. The escape was
   physically impossible.

Consequence: a stay_silent turn under an actionable signal produced
`CompletionContractViolation` → `Tool_required_unsatisfied`
→ `Pause_current_work`. This is not auto-recoverable
(`keeper_error_classify.ml`), and at a streak threshold the keeper is
auto-paused with its task released
(`keeper_unified_turn_failure.ml` `tool_contract_auto_paused`, lines
39-89). The diagnostic attributes a recurring volume of keeper turn
timeouts/pauses to this trap, predominantly on idle/janitor keepers that
correctly decide "no fit" on a turn where claimable tasks exist but none
match the keeper's surface (the `keeper_tool_progress.ml` ~line 63-70
comment population: `claimable_count` 44-46, `idle_seconds` 28-40h).

## Approach

Make the proof a real, optional, typed signal (approach (a): typed
no-work-proof argument), not a deletion of the check (approach (b)).

(b) was rejected: deleting the actionable-signal stay_silent check makes
*every* stay_silent valid, so a keeper can reflexively flee to silence
while real claimable work exists; the only catch would be the
consecutive-stay circuit breaker, N turns later, never on the turn. (a)
keeps the turn-level distinction: deliberate "I looked, no fit" silence
completes; reflexive silence under signal is still blocked.

### Mechanism

1. `keeper_stay_silent` gets its own schema (not the shared
   `empty_object_schema`) with an **optional** `no_work_reason` string
   property constrained to a closed enum
   (`Keeper_tool_outcome.stay_silent_no_work_reasons`). Optional so a
   bare stay_silent on a no-signal turn stays valid; `additionalProperties`
   is omitted to match `object_schema` convention (an optional property
   plus `additionalProperties:false` is rejected by OpenAI strict
   function-calling).

2. `Agent_tool_in_process_runtime.handle_stay_silent` parses
   `no_work_reason`. A recognized value emits
   `typed_outcome: Keeper_tool_outcome.No_progress { reason = No_work_available }`
   embedded in the result JSON. Unknown or absent values emit no
   `typed_outcome` (unknown is **not** a permissive default).

3. The existing typed-outcome channel carries it with no new transport:
   the PostToolUse hook (`keeper_hooks_oas.ml`) already extracts a
   `typed_outcome` field via `Keeper_tool_outcome.of_json`, strips it from
   the LLM-facing output, and threads it onto `tool_call_detail`. This is
   the same channel claim tools use (`agent_tool_task_runtime.ml`).

4. `Keeper_agent_run_actionable_contract.analyze` derives a
   `stay_silent_has_no_work_proof` bool from the stay_silent
   `tool_call_detail`'s `typed_outcome` and passes it to
   `actionable_tool_contract_violation_reason`, which returns `None`
   (turn accepted) when the proof is present and the original violation
   otherwise.

### Variant reuse (not a dedicated variant)

The proof reuses `No_progress { No_work_available }` rather than a new
`Deliberate_no_fit` variant. Rationale: the gate only reads a bool, so the
variant choice is cosmetic for enforcement; `of_json` is a hand-written
string match where a new variant would land on `_ -> None` and silently
drop the proof unless every arm is updated and tested; the only branching
consumer (`keeper_tool_progress.ml` ~line 242) treats `No_work_available`
benignly. Trade-off: `No_work_available` is semantically slightly off
("signal present, no fit" vs "no work exists"); documented in code and
here rather than encoded as a new variant.

## What this does NOT claim

- The proof is **model-asserted, not server-verified**. The server cannot
  verify the model's "no fit" judgment, so a model can attach a proof even
  when real claimable work exists.
- Achievable property: deliberate (proof-carrying) silence completes the
  turn; reflexive (bare) silence under a signal is still blocked;
  repetition is bounded only by the consecutive-stay circuit breaker
  (`keeper_stay_silent_loop_detector.ml`), which is **kept**.
- The escape only takes effect when `claim_context_allowed = true`
  (no owned active task). Under an owned active task, the earlier
  owned-task arm (`keeper_tool_progress.ml` ~line 348) blocks stay_silent
  before the proof arm runs — by design ("own a task, work it"). The
  timeout reduction therefore applies to the no-owned-task subset; the
  full volume is not claimed here.

## Root cause not addressed (named, deferred)

`classify_actionable_signal_for_tools` fires on `count > 0` + capability and
ignores scope/persona fit, which is *why* legitimate no-fit keepers see an
"actionable" signal at all. This RFC makes the resulting trap escapable; it
does not fix the over-claiming signal. A follow-up should narrow the signal
to scope-matched tasks.

## Workaround layers (assessed, none removed)

Three compensating layers were assessed for removal after the root fix.
**None are removed in this change**, because the fix lowers the trap's
*frequency* without making any layer dead, and broken main blocks
behavioral verification of any removal:

| Layer | File:line | Disposition |
|---|---|---|
| Tool-contract auto-pause + task release | `keeper_unified_turn_failure.ml:39-89` | **Keep.** Triggers on `is_required_tool_contract_violation err` (line 40) for ALL contract violations, not just stay_silent. Removing it breaks legitimate stuck-keeper pauses. |
| Consecutive-stay loop detector | `keeper_stay_silent_loop_detector.ml` | **Keep (load-bearing).** The only bound against proof-carrying reflexive silence; this RFC relies on it. |
| Stay-silent loop recovery / mark | `keeper_unified_turn_stay_silent.ml` | **Keep.** Recovery-stimulus + blocker path for the loop detector above. |

Follow-up (separate PR, after main is green): re-measure trap frequency
and reconsider the auto-pause threshold, with behavioral tests.

## Verification

- `@check` net-zero against broken main: the error set is byte-identical
  before/after the change and contains zero errors in the changed files
  (the lib build is broken by unrelated in-flight `keeper_meta_contract`
  field churn). Isolated `.cmo` builds of all 5 changed lib modules pass.
- Tests (in `test/test_keeper_unified_claim_progress.ml`):
  - `no_work_reason_of_stay_silent_arg` accepts the closed enum, rejects
    unknown/empty.
  - the gate flips a violation to `None` only with the proof flag; bare
    silence still violates; no-signal stays valid; non-stay_silent passive
    tools ignore the flag.
  - `stay_silent_no_work_proof_present` reads the proof from a stay_silent
    `typed_outcome`, and does not count a `No_progress` on another tool.
  - the real handler-output → `of_json` round-trip emits `No_progress` for
    a recognized reason and nothing for bare/unknown (the transport seam).

Behavioral (full-suite) execution is blocked on broken main; the seam was
covered by code-read (handler output is non-empty → `outcome = "ok"` via
`tool_result_has_material_progress`, so stay_silent stays in
`progress_keeper_tool_names` and the patched arm is reached, not the
`no_progress_success` first branch).
