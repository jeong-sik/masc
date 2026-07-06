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
| 1 | Thinking-only read-only retry | typed response/effect gate | read-only error/empty payload trace | retry can hide accept failures |
| 2 | Last-tool effect context | final tool plus turn-wide effect summary | compaction/resume multi-message fixture | read-only label can be unsound |
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
typed response shape is `thinking_only`, the final tool is `read_only`, and the
turn-wide checkpoint summary reports `any_mutating_tool=false`.

Missing real-world examples:
- A read-only tool returns an error or empty payload, then the runtime returns
  only thinking text.
- The rejection happens on the final candidate, where retry is intentionally
  impossible.

Operational risk: the fix is intentionally narrow. The earlier string-decorated
reason gate is now typed, but remaining confidence still depends on broader
fixture traces for read-only tool failures and final-candidate behavior.

Evidence fixture needed: a raw checkpoint/rejection fixture with multiple tools,
including final-candidate and read-only error/empty-payload cases.

## 2. Last-tool effect context

Evidence:
- `lib/keeper/keeper_turn_driver_try_provider.ml:195-221`
- `lib/keeper/keeper_turn_driver_try_provider.ml:224-234`

Current behavior: the checkpoint scan records the final assistant `ToolUse` and
a turn-wide effect summary:
`last_tool=<name>; last_tool_effect=<read_only|mutating>; any_mutating_tool=<bool>; tool_effects_seen=<...>`.

Missing real-world examples:
- A turn calls several read-only tools where only the last one is relevant to
  the rejection.
- A checkpoint includes tool-use blocks from multiple assistant messages after
  compaction or resume.

Operational risk: the original "last tool was read-only" false-positive is
covered by `any_mutating_tool`, but compaction/resume checkpoint shape can still
hide relevant tool-use history if it is not preserved in the checkpoint.

Evidence fixture needed: multi-message checkpoint fixtures after compaction or
resume, plus tests that pin which checkpoint spans are authoritative.

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

Status: retired.

Previous behavior: `lib/keeper/keeper_alerting.ml` computed an alert score from
keyword weights plus structural bonuses and could fan out to operator-facing
channels.

Current behavior: the score/fanout path and its `MASC_KEEPER_ALERT_*` /
`MASC_ALERT_DEDUP_WINDOW_SEC` configuration surface were removed. Keeper or
operator escalation must be introduced through typed runtime facts or an
explicit LLM/Fusion boundary, not local keyword weights or numeric thresholds.

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

1. Add compaction/resume checkpoint fixtures that prove the turn-wide
   `any_mutating_tool` summary still sees the authoritative tool-use span.
2. Add provider error corpus tests for hard quota, capacity backpressure,
   terminal runtime failure, and retryable transient errors.
3. Add multilingual board-signal fixtures for Korean goal text, mention false
   positives, and overlapping keeper goals.
4. Add transcript fixtures for confirmation detection, `SKIP:` turn mode, and
   no-result error category mapping.
5. Audit remaining `Runtime_candidate` neutral helper call sites and either
   remove dead compatibility helpers or annotate behavior-affecting consumers.
