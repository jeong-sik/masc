# RFC-0028 — Bounded Token Prediction (Distribution-based)

- **Status**: Draft
- **Author**: yousleepwhen (vincent)
- **Created**: 2026-05-05
- **Audit reference**: `docs/audit-responses/2026-05-05-dashboard-heuristic.md` §8.1
- **Related**: RFC-0026 (work-conserving keeper admission), `lib/bounded.{ml,mli}`

## 1. Problem

`Bounded.check_constraints_with_buffer` predicts the next turn's token cost
with a **linear running average** plus a hard-coded `token_buffer = 5000`
fallback when no turn has run yet. Three concrete defects:

1. **Magic constant.** `5000` has no recorded measurement evidence. It
   is the only fallback used when `state.turns = 0`, i.e. it decides
   whether the very first turn is even attempted under tight token
   budgets.
2. **Linear average misses the tail.** Token output per LLM turn is
   not normally distributed — context length and tool-call expansion
   produce a heavy upper tail. An `avg`-based predictor under-estimates
   on the tail and the predictor's *purpose* is preventing tail-driven
   over-runs.
3. **No model awareness.** The predictor treats all agents as one
   distribution. A 9B-class agent and a 35B-A3B agent have visibly
   different token-output distributions (per `heuristic_metrics`
   sweeps); collapsing them inflates variance and weakens the
   prediction in both directions.

The audit (`deep_audit_dashboard_heuristic.md` §8.1, 2026-05-05)
classifies this as **C — partial truth**: the function is wired into
real control flow (`bounded.ml:310`, `predicted_total > max` →
`Constraint_exceeded`), so the magic genuinely affects loop
termination, but `bounded_run` itself has zero production callers
today (the `masc_bounded_run` MCP tool was pruned — see
`test/test_tools_coverage.ml:795`). The blast radius is the
**library surface** (callable from future tools, exercised by the
test suite) rather than a live keeper turn.

We still fix it properly because: (a) the surface is documented in
`bounded.mli` and tests assert on it, (b) the magic is exactly the
shape of bug `feedback_external_report_widespread_stale_critical_path`
warns about — symptom-patching with environment knobs would just move
the magic.

## 2. Goal

Replace the linear-average + magic predictor with a **per-agent
empirical distribution** of recent output-token samples and predict
the next turn's cost from a high quantile (p95). Add explicit
fallbacks with measurement-source comments where evidence is
unavailable.

## 3. Non-goals

- Adapting the distribution **per model** rather than per agent.
  `Spawn.spawn_result` does not carry a `model` field today, and
  cascading providers can shift an agent's underlying model
  mid-session. A per-agent ring buffer naturally adapts to model
  changes within ~50 turns.
- Replacing the entire `bounded` execution loop. The change is
  surgical: add measurement infrastructure + replace one prediction
  function.
- Persisting samples across server restarts. Distributions are
  reconstructed from the first ~20 turns post-boot; persistence is a
  later optimization if it materializes as a real bottleneck.

## 4. Design

### 4.1 Sample storage

```
module Usage_history : sig
  val record : agent:string -> tokens_out:int -> unit
  val predict_p95 : ?agent:string -> unit -> int
  val reset : unit -> unit         (* test helper *)
end
```

Implementation:

- Module-level `Hashtbl.t (string, int Queue.t)` — one ring buffer
  per agent name. Capacity `max_samples_per_agent = 64`.
- `Mutex.t` (`Stdlib.Mutex`) protects the table. Hold time is bounded
  by hash + ring push, dominated by allocation, well under a
  microsecond — fiber-safety concern is negligible vs. the spawn
  cost of a turn (10 ms+).
- `record` enqueues `tokens_out`, evicts oldest if size > capacity.
- `predict_p95 ~agent` snapshots the queue, sorts a copy, returns
  the value at index `ceil(0.95 * n) - 1`.

### 4.2 Fallbacks

```
val min_samples_for_p95 = 10
val unknown_agent_fallback = 1024
```

- `predict_p95 ~agent` when `n < min_samples_for_p95` → returns
  `unknown_agent_fallback`.
- `predict_p95 ()` (no agent) → returns `unknown_agent_fallback`.

`unknown_agent_fallback = 1024` rationale: the value is a conservative
upper bound for a single LLM turn's output tokens against the
current cascade defaults (`gpt-4o-mini`/`qwen3-9B`/`qwen3-35B-A3B`).
**No formal measurement evidence is currently recorded** — once
`heuristic_metrics` distributions land in a follow-up, this fallback
should be revisited and either confirmed or replaced. This is an
intentional honest gap, surfaced as a code comment, not a hidden
assumption.

p95 vs p99 vs p99.9: chose **p95** because:

- Predictor's *job* is to pre-empt loops that would over-run; firing
  too aggressively (p99+) ends loops that would have completed
  safely. Audit reads of `Constraint_exceeded` reasons should align
  with actual exceedances, not with predictive paranoia.
- Sample size is small (capacity 64). Quantile estimation noise
  grows fast past p95 with that sample size; p99 from 64 samples is
  one or two outliers, not a trend.
- p95 is reversible: we can promote to p99 in a future RFC with a
  one-line constant change once we have sample-size evidence.

### 4.3 Predictor wiring

`check_constraints_with_buffer` is rewritten as:

```
let check_constraints_with_buffer ?next_agent state =
  let predicted_per_turn =
    Usage_history.predict_p95 ?agent:next_agent ()
  in
  let predicted_total =
    state.tokens_in + state.tokens_out + predicted_per_turn
  in
  match state.constraints.max_tokens with
  | Some max when predicted_total > max -> Some (...)
  | _ -> check_constraints state
```

- The `?next_agent` argument is supplied by `bounded_run` from the
  round-robin scheduler before the `try_spawn` call.
- When omitted (e.g. early callers that haven't migrated, or a turn
  with no scheduled agent), the predictor falls back to
  `unknown_agent_fallback` per §4.2.

### 4.4 `record` wiring

Inside `bounded_run` after `update_state state spawn_result`:

```
(match spawn_result.output_tokens with
 | Some tokens when tokens > 0 -> Usage_history.record ~agent ~tokens_out:tokens
 | _ -> ());
```

- Only records when the spawn reports a real token count. Mock
  spawns that omit token counts (some test paths) do not pollute
  the distribution.
- Cost is one hash lookup + bounded queue push. Negligible vs. the
  preceding `Yojson.Safe.from_string` of the spawn output.

### 4.5 `token_buffer` field deprecation path

Removing the field would break `constraints_of_json` JSON inputs
that explicitly set `token_buffer`. Strategy:

1. Field is **kept** in `constraints` and `constraints_of_json`.
2. `default_constraints.token_buffer` becomes `0` (was `5000`) — no
   longer encodes a meaningful prediction default.
3. Field is **no longer read** by `check_constraints_with_buffer`.
4. Field doc comment in `bounded.mli` is updated to mark it
   deprecated and reference this RFC.
5. A future RFC removes the field once external JSON producers
   confirm migration.

## 5. Tests

`test/test_bounded.ml` gains:

- `test_record_then_p95_returns_high_quantile` — record 20 known
  samples, assert `predict_p95` returns the expected sorted-index
  value.
- `test_predict_fallback_under_min_samples` — record 5 samples,
  assert `predict_p95 ~agent` returns `unknown_agent_fallback`.
- `test_per_agent_isolation` — record different distributions for
  two agents, assert `predict_p95` returns each agent's quantile.
- `test_predict_no_samples_uses_fallback` — fresh `reset ()`,
  assert `predict_p95 ~agent` returns `unknown_agent_fallback`.
- `test_check_constraints_with_buffer_uses_distribution` — populate
  history, assert that predictor pre-empts the loop sooner than the
  pre-RFC linear avg would have.

Existing `test_default_constraints` and
`test_default_constraints_buffer` are updated:

- `default_constraints.token_buffer` is now `0`.
- The `mli` / RFC reference is added in a comment near the assertion.

## 6. Performance

`Usage_history.record` and `predict_p95` are called at most once per
turn. Microbenchmark check (informal): on M3 Max, hash + ring push +
sort of ≤64 ints is sub-microsecond, three orders of magnitude
under the 10-ms spawn floor. No measurement-driven gate is needed
for this RFC.

## 7. Migration

This RFC ships as a single PR (PR-D of the audit response stack):

1. RFC document (this file).
2. `lib/bounded.mli` + `lib/bounded.ml` changes.
3. `test/test_bounded.ml` + `test/test_bounded_coverage.ml` updates.
4. `docs/audit-responses/2026-05-05-dashboard-heuristic.md` §8.1
   gets a follow-up commit linking to the merged PR.

No data migration. No keeper restart needed (no production caller).

## 8. Open questions

- **Should the fallback `1024` be parameterised via env var?** No
  for this RFC — adding a knob now is exactly the symptom-patching
  pattern the audit flagged. Re-open if a real producer reports a
  realistic distribution that 1024 mis-serves.
- **Should `check_constraints_with_buffer` fall back to the old
  linear avg when no per-agent samples exist but the global pool
  is non-empty?** No — that re-introduces the
  cross-agent-distribution mixing the RFC removes. The conservative
  fallback is correct.
- **Persisting samples across restart?** Deferred. If keeper turns
  produce ≥20 samples in the first minute post-boot, in-memory is
  sufficient.
