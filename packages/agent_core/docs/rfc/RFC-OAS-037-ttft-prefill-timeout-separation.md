# RFC-OAS-037: Separate the first-event (TTFT/prefill) timeout from the inter-token idle timeout

| | |
|---|---|
| Status | Draft |
| Author | vincent (with Claude analysis) |
| Created | 2026-07-20 |
| Target | `agent_sdk` (oas) |
| Related | [[RFC-OAS-020]] (TTFT instrumentation), [[RFC-OAS-026]] (transport-liveness-carrier), masc [[RFC-0345]] (stream-idle fail-safe floor) |

## 0. Summary

`read_sse` / `read_ndjson` (`lib/llm_provider/http_client.ml`) apply a single `idle_timeout` window to every line read, starting from the `Awaiting_first_event` state. So the wait for the FIRST provider event (time-to-first-token / prefill) is bounded by the same `stream_idle_timeout_s` value used for inter-token idle. For a provider that emits no keepalives during prefill, a legitimate long prefill on a large context is indistinguishable from a hung stream, and the idle timeout cancels the turn (labeled `provider_timeout` / `phase=first_token`). This RFC proposes giving the first-event wait its own budget, distinct from inter-token idle.

## 1. Problem (evidence)

- `http_client.ml`: `let stream_idle_state = ref Awaiting_first_event` — the idle state machine starts before any event. `timeout_phase_of_stream_idle_state`: `Awaiting_first_event | Awaiting_first_delta -> First_token`. `read_sse ?clock ?idle_timeout` wraps each line read in the SAME `with_timeout_exn idle_timeout` window; the deadline resets on ANY SSE event, including keepalives, but pure silence trips it (existing comment: "a provider that emits only keepalives still trips idle_timeout").
- Consequence: there is no separate time-to-first-token allowance. The first-event wait is bounded by `stream_idle_timeout_s`.
- Live evidence (masc fleet, 2026-07-20): keeper `rondo` on runtime `mimo.mimo-v2.5` (`max_context=1000000`) failed a turn with `Provider 'unknown' timeout phase=first_token: stream_idle_timeout_s deadline exceeded while awaiting_first_event`, `latency=152746ms`. The provider emitted no SSE event for the idle window while prefilling a large context; the idle timeout fired and cancelled the turn. The turn was not hung — it was prefilling.

The FSM reaching a `streaming` state is misleading here: that transition marks the HTTP response starting (`ProviderResponded`), not the first token. Internally the stream is still `Awaiting_first_event`.

## 2. The conflation

Two distinct quantities are bounded by one knob:
- **TTFT / prefill latency** — the time until the provider produces its first event. Scales with prompt/context size; for large-context models this is legitimately long and can be silent (no keepalives). A slow-but-alive prefill is NOT a hang.
- **Inter-token idle** — a gap between events AFTER the stream has started producing. A long gap here does indicate a stalled/hung active stream, and a short bound is correct.

Using one short `stream_idle_timeout_s` for both makes the first case a false positive: a valid long prefill is cancelled as if hung.

## 3. Non-goals

- Removing the inter-token idle bound (it is correct and stays short — a stalled active stream must be caught).
- Bounding total response latency (that is `body_timeout_s`).
- Per-provider tuned first-token values (an inferred-default anti-pattern; the first-event budget is a single conservative liveness bound, not a per-model tuning).
- Changing keepalive handling (keepalives already reset the idle timer; providers that send them during prefill are unaffected).

## 4. Design

### 4.1 Options

**Option A — dedicated first-event budget (recommended).**
Add a `first_event_timeout_s : float option` bounding the `Awaiting_first_event` (and `Awaiting_first_delta`) phase, distinct from `stream_idle_timeout_s` which applies only AFTER the first event. `first_event_timeout_s` is a longer, single conservative bound (a truly dead connection still fails; a slow prefill survives). When unset, the first-event phase falls back to `body_timeout_s` (total) rather than the short idle value.
- Pro: clean separation; TTFT telemetry already exists (RFC-OAS-020) to inform the value; each phase bounded by the right concept.
- Con: one more knob; callers threading it (default `None` → body_timeout fallback keeps current callers behaving no worse than an unset idle timeout).

**Option B — idle timeout applies only after the first event.**
Do not arm `stream_idle_timeout_s` until the first event; bound the first-event wait solely with the existing `body_timeout_s` / connect timeout.
- Pro: no new knob.
- Con: the first-event wait is then bounded only by `body_timeout_s` (often large/unset) — weaker protection against a genuinely dead connect than a dedicated, moderate first-event bound.

**Option C — context-scaled first-event allowance.**
Scale the first-event budget by prompt token count (prefill grows with context).
- Pro: most precise.
- Con: requires a model of prefill-rate; complexity and drift; a conservative fixed bound (A) is simpler and sufficient.

### 4.2 Recommendation

**Option A.** Arm `stream_idle_timeout_s` only after the first event; bound `Awaiting_first_event` with `first_event_timeout_s` (a separate, longer liveness bound). This corrects the conflation while keeping a dead-connect guard and the short inter-token idle guard.

**Fallback chain when `first_event_timeout_s` is unset** (updated to match the implementation in #2723):

`first_event_timeout_s` → `body_timeout_s` → `stream_idle_timeout_s` → unarmed.

The draft stopped at `body_timeout_s`. Two arms were added while implementing:

- **`stream_idle_timeout_s`**: before this RFC that value bounded the first event too. A caller that wires only an idle deadline and neither of the other two must keep exactly its previous bound — widening it is an unrequested behaviour change, and the repo's contract tests catch it.
- **unarmed**: with none of the three wired the wait stays unarmed, as before. An earlier revision of #2723 inserted an internal 300s ceiling here; that was wrong twice over — a hardcoded magic number, and a silent reversal of the "omitted means disabled" contract that re-introduced the provider idle defaults which were deliberately removed (pinned by `removed_provider_idle_defaults_upper_bound_s` in `test_complete_http.ml`). Every arm must resolve to a caller-supplied value; this layer never invents a deadline.

A dead connect on the all-unset path is bounded by the connect timeout and by the caller's own total-call deadline, not by a budget this layer makes up.

**Attribution.** A fired deadline names the knob that actually armed it. Before the split every phase was governed by `stream_idle_timeout_s`; naming that knob for a first-event timeout sourced from `body_timeout_s` would send the operator to tune a value with no effect on the phase that failed — defeating the diagnosis this RFC exists to enable. Attribution is derived from the same resolver as the armed bound, so the precedence chain has one definition and the message cannot drift from behaviour.

### 4.3 Interaction with masc RFC-0345

RFC-0345 (merged) adds a masc-side fail-safe floor for `stream_idle_timeout_s`. With this separation, that floor applies to inter-token idle (its intended target); the first-event phase gets its own (larger) bound, so the floor no longer risks cutting a long prefill.

## 5. Acceptance

- A silent prefill that produces its first event within `first_event_timeout_s` (or `body_timeout_s` fallback) completes — NOT cancelled as `provider_timeout`. A regression test with a fake reader that is silent past the old idle timeout but under the first-event budget asserts success.
- A stream with no first event beyond the first-event budget still fails (dead connect guarded).
- A stream that produces a first event then stalls beyond `stream_idle_timeout_s` still fails (inter-token idle guarded) — unchanged.
- Keepalive-emitting providers unchanged.
- **Each arm of the fallback chain is pinned separately** — explicit `first_event_timeout_s` wins over both others; `body_timeout_s` wins over idle; idle applies when it is the only bound; all-unset stays unarmed. A reordering, or a re-introduced built-in default, fails one of these rather than showing up as a timing flake.
- **A caller that wires only `stream_idle_timeout_s` keeps its previous behaviour** — the existing streaming contract tests (`stream` 9/12/14/15/16 in `test_complete_http.ml`) stay green without modification. They are the guard against reviving the removed provider idle defaults, so they must not be relaxed to accommodate this change.
- **A fired timeout names the governing knob**, not `stream_idle_timeout_s` unconditionally. Pinned per source, including one later phase to confirm inter-token timeouts are still attributed to idle.

## 6. Blast radius

- `lib/llm_provider/http_client.ml` (`read_sse` / `read_ndjson` idle-window logic; arm idle only post-first-event), `lib/llm_provider/complete_stream.ml` (thread `first_event_timeout_s`), config plumbing (`agent_types.ml` / `builder.ml`). No wire-format change. No provider-specific logic.

## 7. Workaround-rejection self-check

- Not telemetry-as-fix: this changes control flow (the first-event wait is bounded by the right budget), not just observation.
- Not a string/substring classifier, not N-of-M, not a catch-all, not cap/cooldown/dedup/repair.
- Not an inferred per-provider default (§3): the first-event budget is a single conservative liveness bound, not a tuned per-model value. The change removes a conflation (first-token latency mislabeled as inter-token idle), which is a correctness fix, not symptom suppression.
