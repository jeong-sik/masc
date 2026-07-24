# RFC-0349 — Restore a reachable compaction admission path

- Status: Draft
- Updated: 2026-07-20
- Author: vincent (drafted by Claude Opus 4.8)
- Related: #24906 (removed threshold trigger variants), commit `791eb4bfb4` (replaced automatic admission with a literal), #25051 (Summarizer_unavailable starvation), RFC-0344 (durable store migration — separate)
- Supersedes: none

## 0. Summary

masc currently has **no reachable compaction admission path for the running fleet**. Two commits removed the proactive path, and the one remaining automatic path requires a typed provider error that this fleet's providers structurally cannot emit. The result is measured, not theoretical: every one of the 16 live keepers reports `compaction_count = 0`, and one keeper sits **36% over its provider context window** while its recorded decision stays `not_requested`.

This RFC restores admission **without** resurrecting the removed threshold triggers: it adds a third *explicit request origin* — `Context_high_water` — alongside the existing operator-originated (`Manual`) and provider-originated (`Provider_overflow`) origins, preserving #24906's "caller owns the request" contract.

## 1. Problem (live evidence, 2026-07-20)

### 1.1 The proactive path was replaced by a literal

`lib/keeper/keeper_post_turn.ml`:

```ocaml
let decision = Keeper_compact_policy.Not_requested in
```

This is a constant, not a computation — nothing in scope reads token counts or budgets. Commit `791eb4bfb4` (2026-07-15, "refactor(keeper): require explicit compaction admission") replaced the `Keeper_compact_policy.compact_if_needed_typed` call with it and deleted the last reader of `compaction.ratio_gate / message_gate / token_gate / cooldown_sec`. Commit `9f62efe4a7` (#24906, 2026-07-17) then removed the trigger variants themselves (`Ratio_threshold`, `Message_count`, `Token_count`).

The surrounding code still stamps `last_check_ts = now_ts` every turn, which is why live meta shows a check timestamp that advances while the decision never changes.

### 1.2 The remaining automatic path is structurally unreachable here

The only automatic admission is `keeper_turn_runtime_budget.ml`:

```ocaml
match err with
| Agent_sdk.Error.Api (ContextOverflow { limit; _ }) ->
  Some (Keeper_state_machine.Context_overflow_detected { limit_tokens = limit })
| _ -> None
```

That value cannot arise for this fleet's providers:

- `llm_provider/retry.ml` classifies `400 | 422` as `InvalidRequest`, and an in-tree test **deliberately pins this**: `let%test "HTTP 400 prose does not synthesize ContextOverflow"`.
- The sole producer path requires an Anthropic-shaped `stop_reason = model_context_window_exceeded` empty completion.
- The live fleet runs `glm-coding.glm-5-turbo` and `mimo.mimo-v2.5` — OpenAI-compatible endpoints that return HTTP 400 or truncate server-side.

**Live confirmation**: the 2026-07-20 system log (6.3 MB, through 12:21 KST) contains `overflow` **0 times**, `ContextOverflow` 0 times, `provider_overflow` 0 times — on a day when a keeper sat 36% over its window.

### 1.3 Measured blast radius

All 16 keepers report `compaction_count = 0`, `last_compaction_decision = "not_requested"`:

| keeper | window | last input tokens | ratio |
|--------|--------|-------------------|-------|
| sangsu | 203,000 | 276,173 | **136% — over limit** |
| executor | — | 745,200 | — |
| nick0cave | — | 681,485 | — |
| rondo | 1,000,000 | 598,719 (growing ~6k/min) | 60% |
| verifier | — | 584,187 | — |

sangsu's turns degrade before any provider error is produced (`disposition_reason = "degraded_retry"`, `active_model = null`), so even the reactive path is never reached. Its context cannot shrink, so the condition is permanent: **a keeper that exceeds its window can never recover on its own**.

### 1.4 Why config cannot fix it

The gates were removed at the type level, not disabled at the config level. `keeper_config_text.ml` lists `compaction_ratio_gate`, `compaction_message_gate`, `compaction_token_gate`, `compaction_cooldown_sec`, `compaction_profile` in `removed_keeper_input_key_names`, and `keeper_meta_json_parse.ml` `reject_removed_keeper_meta_shapes` returns an error for each. Adding such a key does not re-enable anything; it fails keeper meta parse. There is deliberately no knob.

## 1.5 The strongest objection: "#24906 purged heuristic triggers — this re-adds one"

Commit `9f62efe4a7` is titled *"refactor(compaction)!: purge heuristic trigger kinds"*. Any proposal that reintroduces a threshold must answer that directly, so:

**What was purged were proxies.** `Message_count` and `Ratio_threshold` estimated "the context is getting big" from indirect signals — message counts and computed ratios against a configured target, tunable per keeper, with a cooldown to damp the resulting churn. That family is genuinely heuristic: the quantity being thresholded is not the quantity that actually fails.

**What this RFC proposes is a measurement against a declared limit.** `window_tokens` is the provider-declared context window (`max-context` in the model catalog, the same value the provider enforces). `used_tokens` is the measured input-token count of the turn that just ran, reported by the provider's own usage accounting. The comparison is "did we measurably use more than the provider says it accepts", not "does some proxy suggest we might be large". sangsu at 276,173 against a declared 203,000 is not an estimate that it *might* overflow — it is a record that it already did.

**The purge's premise is falsified for this fleet.** Removing the proxies was sound only if the non-proxy signal — the provider telling us it overflowed — remained reachable. §1.2 shows it is not: for OpenAI-compatible endpoints that signal is classified as `InvalidRequest` by design, with a test pinning that behaviour. The fleet therefore has neither the proxy nor the signal, which is how a keeper reaches 136% of its window with `not_requested` recorded.

If a future provider does emit typed overflow, `Provider_overflow` remains the preferred origin and `Context_high_water` simply never fires first. The two are not redundant: one is reactive-after-failure, the other is preventive-before-failure, and only the latter can help a keeper whose requests degrade before any provider error is produced.

## 2. Non-goals

- **Do not resurrect** `Ratio_threshold` / `Message_count` / `Token_count`. #24906 removed them on purpose; this RFC keeps admission caller-owned and explicit, and thresholds a measured value against a provider-declared limit rather than a proxy (§1.5).
- **Do not string-match provider prose** on 400 bodies to synthesize `ContextOverflow`. The SDK forbids it with a drift-guard test, and it is a CLAUDE.md signature-2 workaround.
- Do not change how compaction *plans* or *summarizes*; only how it is *requested*.
- Not in scope: the live-config `structured_judge` drift (a separate operational fix, see §6).

## 3. Design

### 3.1 A third explicit request origin

`Compaction_trigger.t` is a closed variant with durable encode/decode. Add one constructor:

```ocaml
type t =
  | Provider_overflow of { limit_tokens : int option }   (* provider-originated *)
  | Manual                                              (* operator-originated *)
  | Context_high_water of { used_tokens : int; window_tokens : int }  (* system-originated *)
```

Rationale for a distinct constructor rather than reusing `Manual`: an operator request and an automatic high-water request are different origins with different operational meaning (one is a human decision, one is a policy). Compressing them into one constructor would erase that distinction in every metric label, log line, and durable detail record. Because the variant is closed and matched exhaustively, adding it forces every consumer to be updated at compile time.

`to_label` / `to_human` / `to_detail_json` / `of_detail_json` gain the corresponding arms, including strict decode validation (`used_tokens` and `window_tokens` must be positive integers) matching the existing `Provider_overflow` treatment.

**Durable-schema note**: the trigger detail is persisted. This addition is *additive* — old records carry only the existing kinds and continue to decode; new records may carry `context_high_water`, which older binaries would reject. Forward-compat is not required here (no downgrade path is supported), but the addition must be listed in the durable-schema inventory tracked by RFC-0344.

### 3.2 Where the request originates

The post-turn lifecycle already computes the values needed and already stamps a decision every turn. Replace the literal with a predicate over values already in scope:

```
resolution = resolve_max_context_resolution_of_meta base_meta
used       = meta.runtime.usage.last_input_tokens
if resolution.effective_budget > 0
   && used * 100 >= compaction_admit_percent * resolution.effective_budget
then request Context_high_water { used_tokens = used; window_tokens = resolution.effective_budget }
else Not_requested
```

`compaction_admit_percent` is a **named constant**, not a literal at the comparison site, and is surfaced in `[runtime]` config so it can be tuned without a rebuild. Suggested initial value: 60 (chosen so a 1,000,000-window keeper admits at ~600k, well before any provider-side truncation, and a 203,000-window keeper admits at ~122k).

Note that `effective_budget` is already computed today for **display only** (`operator_control_context_snapshot.ml` `compute_context_ratio`). This RFC makes the same number load-bearing.

### 3.3 The request must reach an admitted execution

Issuing the request is not sufficient. `compact_for_request_typed` prepares a compaction but explicitly leaves durable save and `Prepared → Applied` promotion to the caller, and the existing admitted path is the heartbeat's compaction lane. That lane has a defect that must be fixed in the same change:

**Manual compaction starves behind the busy turn slot.** Live evidence: a queued manual compaction for rondo was rescheduled 16 times over ~8 minutes (30s cadence) and never obtained the slot; `turn slot busy` appears 15 times in the same window; exactly one `compaction_started` occurred all day. `keeper_heartbeat_loop_cycle.ml` drops the attempt on `` `Busy `` and re-arms for the next heartbeat.

This is a positive feedback loop: the larger the context, the longer the turn, the less likely compaction ever gets the slot — the remedy is least available exactly when it is most needed. Required changes:

1. Give a compaction request a **bounded wait for the slot** instead of an immediate `Busy` drop.
2. Emit a **typed counter and WARN** when a compaction request is dropped as `Busy` N consecutive times. Today the 16 drops are visible only as INFO reschedule lines with no escalation — an operator cannot see that the escape hatch is starving.

### 3.4 Uncompactable histories are out of scope but must fail loudly

Three keepers currently reject compaction terminally with `Keeper_compaction_unit.Overlapping_tool_cycle` at a stable message index — the partitioner is all-or-nothing, so one malformed tool cycle makes the entire checkpoint permanently uncompactable. That is a separate defect (its own RFC). This RFC only requires that a `Context_high_water` request hitting it produces the same typed terminal rejection and counter as a manual request, so the condition is visible rather than silent.

## 4. Acceptance

- **TLA+ bug model** (`specs/bug-models/CompactionAdmission.tla`), per the project convention: `BugAction` = a keeper whose used/window ratio exceeds the admit threshold makes a turn without any admission event; `INVARIANT` = `used_ratio >= admit_threshold ⇒ eventually a compaction request is admitted or a typed terminal rejection is recorded`. Clean cfg must pass; `-buggy.cfg` must violate the same invariant.
- **Counterfactual**: reverting the predicate to the literal `Not_requested` must turn the new regression test red.
- **Slot-starvation regression**: a keeper with a continuously busy turn slot must still admit a queued compaction within the bounded wait, or record the drop counter — asserted, not observed.
- **Live verification**: after deploy, `compaction_count` must become non-zero for at least one keeper above the threshold, and sangsu's `last_input_tokens` must fall below its 203,000 window.

A green unit test alone is not sufficient for §3.3: the starvation only manifests under sustained slot contention, so the regression must simulate a held slot.

## 5. Blast radius

- `lib/compaction_trigger/compaction_trigger.{ml,mli}` — one constructor plus its four total functions and decode arms.
- `lib/keeper/keeper_post_turn.ml` — replace the literal with the predicate.
- `lib/keeper/keeper_heartbeat_loop_cycle.ml` — bounded slot wait plus drop counter.
- Every exhaustive `match` on `Compaction_trigger.t` — the compiler enumerates these; there are two construction sites today (`keeper_unified_turn.ml`, `keeper_manual_compaction.ml`).
- Durable: adds one `kind` value to the persisted trigger detail (additive).

## 6. Interaction with the live `structured_judge` drift

Independently of this RFC, the live config had lost `[runtime].structured_judge`, so the compaction summarizer ultimately resolved to `glm-coding.glm-5-turbo`, which declares `supports-structured-output = false`. At the time this happened through an intermediate migration route that has since been retired; current code falls back directly to `[runtime].default`. Compaction would therefore have been **rejected with `Summarizer_unavailable` even when requested** — the outcome `keeper_compact_policy.ml` already documents ("could never compact, so their history only grew", #25051).

That drift is an operational fix (restore `structured_judge = "ollama_cloud_native.minimax-m3-native-structured"`, the only lane declaring `supports-structured-output = true`), not a code change, and it must be in place for this RFC's acceptance to be observable. It is recorded here so the two are not confused: **restoring the summarizer lane does not restore admission, and restoring admission does not restore the summarizer lane.** Both are required.

## 7. Workaround-rejection self-check (CLAUDE.md)

- This RFC does not add a counter in place of a fix (signature #1): the counter in §3.3 is an escalation signal *alongside* the bounded-wait fix, not instead of it.
- It does not add a string/prose classifier (signature #2): §2 explicitly forbids synthesizing `ContextOverflow` from 400 bodies.
- It is not an N-of-M patch (signature #3): admission is restored at the single point where the decision is computed, not per call site.
- It does not introduce cap/cooldown/dedup/repair symptom suppression. The bounded wait in §3.3 is a scheduling correction with an observable failure counter, not a silence mechanism.
