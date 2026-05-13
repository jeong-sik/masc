# RFC-0045 — SDK turn boundary alignment with MASC keeper FSM

Status: Draft
Author: jeong-sik
Date: 2026-05-08
Supersedes: —
Related: RFC-0044 (typed persistence read-drop), PR #14194 (FSM unify
validation), PR #14207 (Decision_gate_rejected → Decision_tool_policy_selected
transition fix)

## 1. Problem

Production keeper crashed with an `Assert_failure` from
`validate_turn_phase_transition`:

```
[2026-05-08 20:58:22] [INFO] [Keeper] context overflow guard: 24 tools > max 15, truncating
[2026-05-08 20:58:22] [ERROR] [Misc] oas_worker oas-big_three: execution exception:
File "lib/keeper/keeper_registry.ml", line 775, characters 7-13: Assertion failed
Backtrace:
  Masc_mcp__Keeper_registry.validate_turn_phase_transition
  Masc_mcp__Keeper_fsm_guard_runtime.wrap_unit
  Masc_mcp__Keeper_registry.set_turn_cascade_state
  Masc_mcp__Keeper_registry.update_current_turn
  Masc_mcp__Keeper_registry.update_entry.loop
  Masc_mcp__Keeper_registry.set_turn_cascade_state
  Masc_mcp__Keeper_run_tools.prepare_agent_setup.(fun)
  Masc_mcp__Memory_hooks.compose_before_turn_params.(fun)
  Agent_sdk_base__Hooks.invoke_validated
  ...
  Agent_sdk__Pipeline.run_turn
  Agent_sdk__Agent.run_turn_core
  Agent_sdk__Agent.run_loop.(fun).loop          ← multi-turn boundary
  ...
  Masc_mcp__Oas_worker_exec.run

[2026-05-08 20:58:52] [INFO] [Keeper] executor: auto-resume blocked;
    cascade retired_tool_profile is unhealthy
```

The keeper went down and `auto-resume blocked` followed.

## 2. Background — turn boundary model mismatch

`keeper_registry` carries a per-keeper `current_turn_observation` with a
`turn_phase` FSM (5 states: `Turn_idle`, `Turn_prompting`, `Turn_executing`,
`Turn_compacting`, `Turn_finalizing`). PR #14194 unified the validators so
every transition flows through `validate_turn_phase_transition`, with the
explicit invariant that "new turn init is reset, not transition" — i.e. the
only way out of a terminal phase (`Turn_finalizing`) into a fresh
`Turn_prompting` is via `mark_turn_started`, which **bypasses** the validator
and installs a fresh observation directly.

The mismatch:

| Layer | Turn boundary marker |
|---|---|
| MASC keeper | `mark_turn_started` (`keeper_unified_turn.ml:785`) — runs **once** before `Agent_sdk.run_loop` |
| MASC keeper | `mark_turn_finished` (`keeper_unified_turn.ml:867`) — runs **once** after `Agent_sdk.run_loop` returns |
| Agent SDK | `Agent.run_loop.(fun).loop` (`agent.ml:175`) — iterates **N SDK turns** until exit condition |
| Agent SDK | `before_turn_params` hook fires **per SDK turn**, calling MASC's `compose_before_turn_params` → `prepare_agent_setup` → `set_turn_cascade_state(Cascade_selecting)` → `Turn_prompting` |

So **1 MASC keeper-turn ≠ 1 SDK turn**. MASC's FSM was modeled as if the two
boundaries coincide; in reality the SDK runs N turns inside a single
`mark_turn_started` / `mark_turn_finished` window, and only the first SDK
turn lands cleanly because `obs.turn_phase` is `Turn_prompting` (set by
`mark_turn_started`). On any subsequent SDK turn, `obs.turn_phase` is the
terminal state of the previous SDK turn (typically `Turn_finalizing` after
`Cascade_done` or `Cascade_exhausted`), and the validator rejects the
`Turn_finalizing → Turn_prompting` transition.

The crash log's `context overflow guard: 24 tools > max 15, truncating` is a
single-turn diagnostic, not the trigger; the trigger is the SDK proceeding to
the **next** turn after the first one terminated.

## 3. Constraints / Invariants to preserve

1. `mark_turn_started` / `mark_turn_finished` define the **MASC keeper turn**
   — usage counters (`total_turns`), supervisor watchdogs, dashboard
   composite events, and `Keeper_registry.usage_metrics` all count
   keeper-turns, not SDK turns. Any change must not double-count.
2. `current_turn_observation` is read by:
   - dashboard composite observer (live `Executing` / `Selecting` surface)
   - `validate_*_transition` family (FSM correctness gates)
   - `set_turn_cascade_state` / `set_turn_phase` / `set_turn_decision_stage`
     (in-turn writers)
3. PR #14194 invariant: every transition flows through a validator. Direct
   `obs` overwrites without validation are a regression.
4. SDK turns can fail / retry / compact / finalize independently. Each SDK
   turn boundary is a real state-machine event; making it visible has
   diagnostic value.

## 4. Options analyzed

### Option A — SDK-turn boundary becomes a first-class concept (recommended)

Introduce a per-SDK-turn reset, distinct from `mark_turn_started`:

- New: `Keeper_registry.mark_sdk_turn_started ~base_path name` —
  resets `current_turn_observation` to a fresh in-turn shape
  (`turn_phase = Turn_prompting`, `cascade_state = Cascade_idle`,
  `decision_stage = Decision_undecided`), **does not** increment
  `total_turns`.
- New: `Keeper_registry.mark_sdk_turn_finished ~base_path name` —
  optional, captures the terminal phase of the previous SDK turn for
  diagnostics (e.g. distinguishing `Cascade_done` vs `Cascade_exhausted`
  endings) before the reset.
- Wire `compose_before_turn_params` (`memory_hooks.ml:73`) to call
  `mark_sdk_turn_started` at the start of each hook invocation. This is the
  natural SDK-turn boundary signal — the SDK invokes
  `before_turn_params` exactly once per SDK turn.
- Keep `mark_turn_started` / `mark_turn_finished` semantics unchanged: they
  remain the MASC keeper-turn boundary, drive `total_turns`, and bracket the
  whole `Agent_sdk.run_loop` call.

Trade-offs:
- Requires touching `Keeper_registry` API (`.mli`), `memory_hooks.ml`, and
  the FSM validator's comment table.
- Does not introduce a new validator-visible transition; the SDK-turn
  boundary is *outside* the validator, exactly like `mark_turn_started`
  already is.
- Makes per-SDK-turn diagnostics (terminal phase of previous SDK turn,
  truncation events, ContextOverflow signals) attributable to the right
  boundary.
- Does not change `total_turns`, so dashboards and supervisor restart
  budgets remain on keeper-turn semantics.

### Option B — Spec table widening

Add `(Turn_finalizing, Turn_prompting) -> true` (and any companion
transitions surfaced by future SDK paths) to the validator table, with a
comment "via SDK run_loop multi-turn boundary".

Trade-offs:
- Smallest diff (one line + comment), matches PR #14207 pattern.
- **Widens the spec invariant**: the original "new turn is reset, not
  transition" rule becomes "...except across SDK-turn boundaries". The
  validator no longer prevents stale-finalizing reads from being mistaken
  for fresh in-turn writes inside a single keeper-turn.
- Risk: future SDK paths (e.g. compaction-mid-loop or accept-rejected retry
  inside `run_loop`) may surface more boundary transitions; each will be
  appended as a new "valid" entry, eroding the validator's discrimination.

### Option C — Implicit reset inside `prepare_agent_setup`

Have `prepare_agent_setup` overwrite `obs` to fresh state on entry, similar
to how `mark_turn_started` does today.

Trade-offs:
- Bypasses validator just like `mark_turn_started` already does — same
  invariant cost as A but without exposing the boundary as a named API.
- Conflates "agent setup" (a configuration step that may be called more
  than once per SDK turn under retry paths) with "SDK-turn started" (a
  boundary that fires once per SDK turn). They are not the same event.
- Hidden side effect on a function whose name does not signal state mutation.

### Option D — `set_turn_cascade_state` self-heals on `Turn_finalizing → Turn_prompting`

Detect the boundary inside `set_turn_cascade_state` and reset `obs` instead
of calling the validator.

Trade-offs:
- Localizes the special case to the writer, not the validator.
- Multiplies the boundary-handling logic across every writer that might be
  the first in-turn write (today `set_turn_cascade_state`; tomorrow possibly
  `set_turn_decision_stage` or `set_turn_phase`). The same special case
  would need to be repeated in each writer, or factored out — at which
  point Option A (a named boundary helper) is cleaner.

## 5. Recommendation

**Option A.** SDK-turn boundary is a real concept and should be named.
Hiding it (Option C) or appending exceptions to the spec (Option B) trades
short-term diff size for long-term confusion every time someone investigates
a transition reject. Option D solves the same symptom but distributes the
boundary logic.

Cost: ~50–80 LoC including `.mli`, registry wiring, hook integration, and a
test case. Comparable to PR #14194 in scope but on a smaller surface.

## 6. Stop-gap (production blocker)

The keeper is currently going down and `auto-resume blocked` follows.
Production needs a fix today; the RFC-A implementation will land on the
order of days.

Per `instructions/software-development.md` §"워크어라운드 거부 기준" override
clause (production-blocking allowed with `WORKAROUND:` label + replacement
RFC link + removal target):

- Land **Option B** as a one-line `false → true` in `validate_turn_phase_transition`:
  ```
  | (Turn_finalizing, Turn_prompting) -> true
    (* WORKAROUND (RFC-0045): SDK run_loop runs N SDK turns inside one
       MASC keeper-turn; mark_turn_started fires once per keeper-turn,
       so the next SDK turn's prepare_agent_setup transitions back from
       a Cascade_done/Cascade_exhausted-derived Turn_finalizing to
       Turn_prompting. Remove this entry once mark_sdk_turn_started is
       wired in compose_before_turn_params (RFC-0045 §5). *)
  ```
- PR body labels: `WORKAROUND: production-blocking, removed by RFC-0045`.
- Removal target: when the RFC-A implementation merges. The same PR that
  wires `mark_sdk_turn_started` reverts this entry.

If production is **not** currently down (i.e. the keeper recovered or the
operator already paused it), the stop-gap should be skipped and only
Option A should land — to preserve the spec's "new turn is reset, not
transition" invariant.

## 7. Migration plan

| Step | Change | Reverts when |
|---|---|---|
| 1 | Stop-gap PR: Option B with `WORKAROUND` label | Step 4 lands |
| 2 | RFC-0045 merge (this document) | — |
| 3 | Implementation PR: `mark_sdk_turn_started` API + wire into `compose_before_turn_params` + tests | — |
| 4 | Revert PR: remove the Option-B `WORKAROUND` entry from validator | — |

Steps 1 and 2 can land in parallel. Step 3 should not land before Step 2
(the validator entry exists in `main` and the implementation has not).

## 8. Test plan

- Unit: a regression test that simulates two SDK-turn boundaries within one
  `mark_turn_started` window and asserts no `Assert_failure`. Today this
  test would crash; with `mark_sdk_turn_started` it passes.
- Property: starting from any terminal `turn_phase` (`Turn_finalizing`,
  `Turn_idle`), `mark_sdk_turn_started` lands the observation in
  `Turn_prompting × Cascade_idle × Decision_undecided` without invoking
  the validator.
- Integration: a fixture keeper that triggers `Cascade_done` followed by
  another SDK turn (via small `max_turns` and a model that returns
  text-then-tool-then-text). Verify metric `keeper_sdk_turn_count`
  (proposed companion gauge) increments per SDK turn while
  `keeper_turn_count` increments per keeper-turn.

## 9. Open questions

1. Should `mark_sdk_turn_started` also reset `selected_model` and
   `measurement`, or carry them forward across SDK turns inside one
   keeper-turn? The current bug only affects `turn_phase`, but consistency
   matters for the dashboard composite observer.
2. Should there be a `keeper_sdk_turn_count` Prometheus gauge to give
   operators visibility into how often this happens? (Adds noise; defer to
   an audit pass that observes the count in production for a week.)
3. Are there other writers (besides `set_turn_cascade_state` via
   `prepare_agent_setup`) that fire on per-SDK-turn boundary today and
   would also benefit from boundary reset? Audit candidates:
   `set_turn_decision_stage`, `set_turn_phase`,
   `set_turn_selected_model`. Likely no — `decision_stage` and
   `selected_model` carry across the SDK turn intentionally — but worth
   verifying.

## 10. Refs

- PR #14194 — `refactor(keeper): unify FSM validation — remove all bypass
  paths` — established the "every transition flows through validator"
  invariant this RFC operates under.
- PR #14207 — `fix(keeper): allow Decision_gate_rejected →
  Decision_tool_policy_selected transition` — the prior 1-line stop-gap
  whose pattern Option B follows.
- `instructions/software-development.md` §"AI 코드 생성 안티패턴 #4 — FSM
  Sparse Match" — the rule the validator enforces.
- `instructions/software-development.md` §"워크어라운드 거부 기준" —
  rationale for the stop-gap labeling protocol.
