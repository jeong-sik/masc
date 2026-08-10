# RFC-OAS-038: Content-first stop_reason derivation (consolidate the reconcile case-pile)

| | |
|---|---|
| Status | Draft |
| Author | vincent (with Claude analysis) |
| Created | 2026-07-20 |
| Target | `agent_sdk` (oas) |
| Related | [[RFC-OAS-035]] (openai-compat thinking-token / empty-completion failclose), oas#2728 (EndTurn+tool-blocks patch — the motivating instance this RFC consolidates) |

## 0. Summary

`Stop_reason_wire.reconcile` (and the parallel `of_finish` non-streaming path) reconciles a provider's `finish_reason` CLAIM against the OBSERVED content (whether tool_use blocks are present) by enumerating per-finish-reason upgrade cases. Each new provider that mislabels tool calls adds a case (`UnmatchedToolCalls`+blocks → StopToolUse; `Unknown`+blocks → StopToolUse; and oas#2728 adds `EndTurn`+blocks → StopToolUse). This is claim-first-with-exceptions and accretes. This RFC replaces it with a single content-first rule: when tool_use blocks are present and the finish_reason is not a truncation/terminal reason, the effective stop_reason is `StopToolUse`. One rule, total over all finish_reasons (including future/unknown ones), derived in ONE place shared by both the streaming (`reconcile`) and non-streaming (`of_finish`) paths.

## 1. Problem (evidence)

- `lib/llm_provider/stop_reason_wire.ml` `reconcile`:
  ```
  | StopToolUse when not has_tool_blocks -> UnmatchedToolCalls
  | UnmatchedToolCalls when has_tool_blocks -> StopToolUse
  | Unknown _ when has_tool_blocks -> StopToolUse
  | (StopToolUse | EndTurn | MaxTokens | ... ) -> sr
  ```
  Each case is a reaction to a specific provider inconsistency. oas#2728 had to ADD `EndTurn when has_tool_blocks -> StopToolUse` because a provider labels complete tool_calls `finish_reason=stop`. The next mislabeling provider needs the next case.
- Duplication smell: the non-streaming OpenAI parser (`backend_openai_parse.ml:386`) calls `of_finish` DIRECTLY, not through `reconcile`. So the same upgrade logic lives in TWO places (`of_finish`'s `Stop` arm and `reconcile`'s arms) that must be kept in sync by hand — oas#2728 had to patch both. A `%test` asserts parity, but parity-by-test is weaker than parity-by-construction.
- The design conflates two authorities: the provider's `finish_reason` (a claim, unreliable across providers) and the response content (tool_use blocks — authoritative, since a tool_use block only exists because the model requested a tool call).

## 2. Non-goals

- Executing tool blocks on a TRUNCATED response (`MaxTokens` — the tool call may be incomplete JSON) or a genuinely terminal one (`Refusal`, `ContentFilter`). Those stay terminal; content-first does NOT mean "always execute blocks".
- Changing `provisional_of_string` (the faithful per-token wire claim; reconciliation applies after accumulation).
- Per-provider tuning (this removes per-provider cases, it does not add them).

## 3. Design

### 3.1 Two sets of finish reasons

Partition `Types.stop_reason` (excluding StopToolUse/UnmatchedToolCalls, which already encode tool intent) into:

- **`execute_on_blocks`** — reasons that, WITH tool blocks, mean "the model completed a normal turn and is requesting tools; the finish_reason is a provider mislabel": `EndTurn` (wire `stop`/`end_turn`), and the already-handled `Unknown _`. (`UnmatchedToolCalls` is the pre-classified tool-intent-without-clean-label case → also StopToolUse with blocks.)
- **`terminal_no_execute`** — reasons where executing a stray tool block is unsafe or ambiguous: `MaxTokens` (truncation — incomplete tool call), `Refusal`, `ContentFilter`, `RepetitionTruncation`, `StopSequence`, `PauseTurn`, `Compaction`, `ContextWindowExceeded`. WITH blocks, these stay terminal (no execute).

### 3.2 The single rule

A shared predicate `effective_stop_reason ~has_tool_blocks (sr : stop_reason) : stop_reason`:
```
if has_tool_blocks then
  match sr with
  | StopToolUse | UnmatchedToolCalls | EndTurn | Unknown _ -> StopToolUse   (* execute_on_blocks *)
  | MaxTokens | Refusal | ContentFilter | RepetitionTruncation
  | StopSequence | PauseTurn | Compaction | ContextWindowExceeded -> sr     (* terminal_no_execute *)
else
  match sr with
  | StopToolUse -> UnmatchedToolCalls   (* claimed tools but none present *)
  | other -> other
```
- Exhaustive `match` (no catch-all): a NEW `stop_reason` variant forces a compile-time decision about which set it joins — the accretion becomes compiler-enforced, not silent.
- BOTH `reconcile` and `of_finish` are defined in terms of this ONE predicate (of_finish maps the wire finish_reason then applies it; reconcile applies it post-accumulation). Parity is by construction; the `%test` becomes a redundant guard, not the sole guarantee.

### 3.3 Relationship to oas#2728

oas#2728 (the `EndTurn`+blocks patch, pending) is the motivating instance. This RFC SUPERSEDES its ad-hoc arm addition with the consolidated predicate. Sequencing: land oas#2728 first (it unblocks the live dangling-tool_use root now); this RFC's refactor folds it into the rule as a follow-up so the codebase does not carry a growing case list.

## 4. Acceptance

- Any finish_reason in `execute_on_blocks` + tool blocks → StopToolUse, INCLUDING a hypothetical future/unknown reason (Unknown is in the set). A new provider mislabel needs NO new code.
- `terminal_no_execute` + blocks → the reason is preserved (no execution) — MaxTokens truncation test, Refusal test.
- No blocks + StopToolUse → UnmatchedToolCalls (unchanged).
- `of_finish` and `reconcile` produce identical results for every (finish_reason, has_tool_blocks) pair — asserted by property test over the full product, not a spot check.

## 5. Blast radius

- `lib/llm_provider/stop_reason_wire.ml` (`reconcile`, `of_finish`, new shared predicate), `.mli` docs. No wire-format change. Behavior change vs today: `Refusal`/`ContentFilter`/`StopSequence`/etc. + blocks are now EXPLICITLY terminal (they already were `-> sr`, so no change); the only behavior addition is the oas#2728 `EndTurn`+blocks case, already reviewed there.

## 6. Workaround-rejection self-check

- This is the OPPOSITE of symptom suppression: it REMOVES a per-provider case-pile and replaces it with one exhaustive, total rule (anti-accretion). It does not add a string/substring classifier — it partitions a closed typed sum. It removes hand-synced duplication (of_finish vs reconcile) by construction. The `terminal_no_execute` exclusions are principled (truncation/terminal safety), documented, and compiler-enforced for future variants.
