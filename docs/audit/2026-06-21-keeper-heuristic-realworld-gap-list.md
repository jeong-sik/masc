---
status: reference
last_verified: 2026-06-21
code_refs:
  - lib/keeper/keeper_turn_driver_try_runtime.ml
  - lib/keeper/keeper_turn_driver_try_provider.ml
  - lib/keeper/keeper_tool_registry.ml
  - lib/keeper/keeper_turn_driver_provider_attempt.ml
  - lib/keeper/keeper_error_classify.ml
  - lib/runtime/runtime_candidate.ml
  - lib/keeper/keeper_world_observation_board_signal.ml
  - lib/keeper/keeper_unified_metrics_support.ml
  - lib/keeper/keeper_alerting.ml
  - lib/keeper/keeper_runtime_trust_timeline.ml
---

# Keeper Heuristic Real-World Gap List

> Date: 2026-06-21
> Scope: MASC keeper/runtime heuristics that affect retry, wakeup,
> observability, or operator escalation.
> Method: adversarial read-through of keeper/runtime code paths after the
> thinking-only read-only accept-rejection fix.
> Status: findings documented; not all entries are bugs. Each entry names the
> missing real-world fixture or operational example that would make the
> heuristic defensible.

## Inclusion criteria

This list includes code when all of the following are true:

- The implementation changes runtime behavior or operator-visible
  classification.
- The decision is driven by a string match, score, threshold, last-event
  summary, or no-op/default stub.
- The code lacks a concrete real-world example or fixture that shows the
  intended behavior and the nearest false-positive/false-negative boundary.

Out of scope: OAS provider/model transport internals, typed OAS response shape
contracts, and pure documentation text. MASC should consume those surfaces
through explicit boundary data rather than grow provider-specific behavior in
OAS.

## Summary

| # | Surface | Current heuristic | Missing example class | Risk |
|---|---------|-------------------|-----------------------|------|
| 1 | Thinking-only read-only retry | accept reason substring gate | actual no-progress trace after read-only tool | retry can hide accept failures |
| 2 | Last-tool effect context | only the final assistant tool call is inspected | multi-tool turn with earlier mutation | read-only label can be unsound |
| 3 | Tool read-only registry | descriptor/capability fallback | mixed-mode tool contracts | checkpoint boundary can drift |
| 4 | Provider error string classifiers | quota/capacity/terminal substrings | provider/CLI error corpus | wrong cooldown/escalation |
| 5 | Keeper warn/recoverable classifier | typed bucket allow/deny list | operator-facing failure samples | noisy or silent incidents |
| 6 | Runtime candidate neutral stubs | default 0/false/1.0/None | local runtime health examples | dashboards imply certainty |
| 7 | Board wake/stigmergy match | mention substring and keyword score | Korean/punctuation/false-positive posts | irrelevant keeper wakeups |
| 8 | Metrics/turn-mode classifiers | output prefixes and phrase search | multilingual turn transcripts | misleading autonomous status |
| 9 | Alert scoring | uncalibrated keyword weights | incident/non-incident corpus | missed or inflated alerts |
| 10 | Trust timeline severity | event-type substring severity | benign event names with trigger words | inaccurate timeline severity |

## 1. Thinking-only read-only retry

Evidence:
- `lib/keeper/keeper_turn_driver_try_runtime.ml:69-78`
- `lib/keeper/keeper_turn_driver_try_runtime.ml:251-257`

Current behavior: typed `Accept_rejected` with
`Accept_no_usable_progress` is retryable on the next runtime only when the
free-form reason contains both `shape=thinking_only` and
`last_tool_effect=read_only`.

Missing real-world examples:
- WebFetch/Read/Grep succeeds, then the runtime returns only thinking text.
- A read-only tool returns an error or empty payload, then the runtime returns
  only thinking text.
- The last tool is read-only but an earlier tool in the same turn mutated
  workspace or board state.
- The rejection happens on the final candidate, where retry is intentionally
  impossible.

Operational risk: the fix is intentionally narrow, but its safety rests on a
string-decorated reason. Without fixture traces for the false-positive
boundary, a future reason-format change can silently stop retrying, or a
misclassified read-only context can retry after a turn that already had side
effects.

Evidence fixture needed: a raw checkpoint/rejection fixture with multiple tools,
including at least one read-only-only turn and one earlier-mutation turn.

## 2. Last-tool effect context

Evidence:
- `lib/keeper/keeper_turn_driver_try_provider.ml:195-221`
- `lib/keeper/keeper_turn_driver_try_provider.ml:224-234`

Current behavior: the checkpoint scan records only the final assistant
`ToolUse` and formats it as `last_tool=<name>; last_tool_effect=<read_only|mutating>`.

Missing real-world examples:
- A turn calls `Edit` then `Read`, and the model produces no deliverable.
- A turn calls several read-only tools where only the last one is relevant to
  the rejection.
- A checkpoint includes tool-use blocks from multiple assistant messages after
  compaction or resume.

Operational risk: "last tool was read-only" is not the same as "this turn was
read-only". Retry decisions built on the last tool alone can ignore earlier
side effects.

Evidence fixture needed: a checkpoint summary that includes `any_mutating_tool`,
`last_tool_effect`, and `tool_effects_seen`, plus tests that pin the intended
precedence.

## 3. Tool read-only registry and checkpoint boundary

Evidence:
- `lib/keeper/keeper_tool_registry.ml:134-154`
- `lib/tool_orchestration/tool_job.ml:38-47`

Current behavior: read-only classification comes from keeper read-only sets,
descriptor capabilities, idempotent capability, or input-aware descriptor
resolution. Tool jobs use catalog metadata and fall back to write semantics for
unknown tools.

Missing real-world examples:
- A mixed-mode public tool where the same tool name has both read and write
  subcommands.
- A descriptor with `Idempotent` capability but nontrivial external side
  effects.
- An unregistered tool that is read-only in practice but defaults to
  `write:any` in scheduling.

Operational risk: read-only status is consumed by retry, checkpoint boundary,
governance risk, and scheduler resource keys. A single descriptor/capability
mistake can fan out to multiple runtime policies.

Evidence fixture needed: descriptor-level examples for mixed-mode tools,
idempotent-but-mutating tools, and unknown tools, with expected boundary and
resource-key behavior.

## 4. Provider error string classifiers

Evidence:
- `lib/keeper/keeper_turn_driver_provider_attempt.ml:178-201`
- `lib/keeper/keeper_turn_driver_provider_attempt.ml:221-240`

Current behavior: hard quota, capacity backpressure, and terminal runtime
failures are detected by substring indicators in provider/CLI error messages.

Missing real-world examples:
- Actual current OpenAI-compatible, Ollama Cloud, Claude CLI, and local runtime
  error envelopes for 429, capacity, timeout, SSE parse, and JSON-RPC parse
  cases.
- A transient overload message that contains quota-like words but should remain
  retryable.
- A hard quota message wrapped in a CLI exception whose wording changes.

Operational risk: these classifiers control health recording and fallback
behavior. Misclassification can either keep hammering a quota-exhausted account
or prematurely suppress a recoverable provider.

Evidence fixture needed: a provider-error corpus with expected
`hard_quota`, `capacity_backpressure`, `terminal_runtime_failure`, and
`retryable` labels.

## 5. Keeper warn/recoverable classification

Evidence:
- `lib/keeper/keeper_error_classify.ml:682-709`

Current behavior: auto-recoverable errors are a small OR-list, and
`should_warn_keeper_cycle_failed` warns for provider timeout and capacity
backpressure while suppressing many typed MASC internal errors, including
accept rejection and runtime exhausted.

Missing real-world examples:
- Operator-facing examples showing which keeper-cycle failures should page,
  warn, or remain routine.
- A thinking-only accept rejection after a read-only tool versus after a
  mutating tool.
- A provider timeout caused by a user-configured too-small wall-clock budget
  versus a provider outage.

Operational risk: the system can become quiet about failures that are
actionable, or noisy about failures that the keeper will recover from
automatically.

Evidence fixture needed: a table of real log lines mapped to
`auto_recoverable`, `warn_cycle_failed`, and expected operator action.

## 6. Runtime candidate neutral stubs

Evidence:
- `lib/runtime/runtime_candidate.ml:107-112`
- `lib/runtime/runtime_candidate.ml:158-172`
- `lib/runtime/runtime_candidate.ml:189-222`

Current behavior: several candidate helpers intentionally return neutral values
after single-binding dispatch collapsed old multi-candidate machinery:
context window hint is `0`, header sync is `false`, unmetered provider is
`false`, threshold multipliers are `(1.0, 1.0)`, recovery evidence is `false`,
and unhealthy local runtime filtering is a no-op.

Missing real-world examples:
- Local runtime with known context window and no auth.
- Remote provider with provider-specific health cooldown.
- A local endpoint that is unhealthy while another configured runtime URL is
  healthy.

Operational risk: neutral stubs are acceptable only if no decision relies on
them. When dashboards, health gates, or context-budget math read these helpers,
the neutral value looks like fact rather than "not modeled".

Evidence fixture needed: an inventory of every remaining call site, marking
each helper as display-only, dead compatibility, or behavior-affecting.

## 7. Board wake and stigmergy matching

Evidence:
- `lib/keeper/keeper_world_observation_board_signal.ml:73-95`
- `lib/keeper/keeper_world_observation_board_signal.ml:152-171`
- `lib/keeper/keeper_world_observation_board_signal.ml:196-216`

Current behavior: explicit mention uses lowercase substring search for
`@target`; stigmergy splits goal text on spaces, keeps tokens longer than
three characters, adds 5 points per substring hit, and wakes on any score above
zero.

Missing real-world examples:
- Korean board posts where space-based tokenization is weak.
- `@target` appearing inside code, URLs, quoted text, or another user's longer
  identifier.
- Multiple keepers with overlapping goals and short shared keywords.

Operational risk: keepers can wake on irrelevant board noise, or miss relevant
Korean/non-space-delimited posts. That directly affects parallel-agent
scheduling pressure.

Evidence fixture needed: a multilingual board-signal fixture set with explicit
mention, false mention, goal overlap, and non-overlap cases.

## 8. Metrics and turn-mode classifiers

Evidence:
- `lib/keeper/keeper_unified_metrics_support.ml:328-353`
- `lib/keeper/keeper_unified_metrics_support.ml:431-436`
- `lib/keeper/keeper_unified_metrics_support.ml:490-498`

Current behavior: no-result errors are bucketed with prefix/substring checks;
turn mode treats `SKIP:` text as skip text; confirmation requests are detected
with `?`, English phrases, and a small Korean phrase list.

Missing real-world examples:
- A status update that says "let me know" but does not require confirmation.
- Korean declarative text ending with a substring that looks like a question.
- User content or tool output that begins with `SKIP:` but is not a keeper skip
  decision.

Operational risk: autonomous reports can mislabel a productive turn as a noop,
or treat a status report as a blocked request for operator input.

Evidence fixture needed: transcript fixtures for visible reply, tool-use-only,
skip, noop, confirmation request, and non-confirmation status update.

## 9. Alert scoring

Evidence:
- `lib/keeper/keeper_alerting.ml:155-207`
- `lib/keeper/keeper_alerting.ml:209-245`

Current behavior: alert score is a sum of keyword weights plus structural
bonuses. The code already notes these values are heuristic and not empirically
calibrated.

Missing real-world examples:
- Incident posts that should alert.
- Similar words in non-incident discussion, documentation, or historical
  summary that should not alert.
- Combined low-alignment and multi-tool cases where the alert should or should
  not cross the configured threshold.

Operational risk: alert fatigue or missed incident escalation. The risk is
larger because this code fans out to operator-facing alert channels and has
dedup logic keyed only by keeper and reason list.

Evidence fixture needed: a labeled incident/non-incident corpus with expected
score bands and emitted reasons.

## 10. Runtime trust timeline severity

Evidence:
- `lib/keeper/keeper_runtime_trust_timeline.ml:85-106`

Current behavior: approval and transition timeline severity is inferred from
event strings. `reject` makes a resolved approval bad; `failed` or `exhausted`
makes a transition bad; `pause`, `stop`, `handoff`, or `compaction` makes it
warn.

Missing real-world examples:
- Benign event names containing `stop`, `failed`, or `reject` as part of a
  larger advisory or historical label.
- Transition events where the typed operator signal severity should override
  the event-type substring.
- Approval decisions with provider-specific wording that includes `reject` but
  is not a denied approval.

Operational risk: timelines can overstate or understate severity, which weakens
trust in keeper monitoring during incidents.

Evidence fixture needed: timeline-event fixtures with typed severity expected
outputs and examples that prove substring fallbacks are only fallback behavior.

## Recommended follow-up test slices

1. Add multi-tool accept-rejection fixtures that distinguish `last_tool_effect`
   from `any_mutating_tool`.
2. Add provider error corpus tests for hard quota, capacity backpressure,
   terminal runtime failure, and retryable transient errors.
3. Add multilingual board-signal fixtures for Korean goal text, mention false
   positives, and overlapping keeper goals.
4. Add transcript fixtures for confirmation detection, `SKIP:` turn mode, and
   no-result error category mapping.
5. Audit remaining `Runtime_candidate` neutral helper call sites and either
   remove dead compatibility helpers or annotate behavior-affecting consumers.
