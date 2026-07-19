---
rfc: "compaction-deterministic-floor"
title: "Compaction must never deadlock: a deterministic structural floor, typed outcomes, and de-coupled model gating"
status: Draft
created: 2026-07-19
updated: 2026-07-19
author: vincent
supersedes: []
superseded_by: []
related: ["0042", "0257", "worldstate-observation-channel-split"]
implementation_prs: [25270, 25281]
---

# RFC-compaction-deterministic-floor

## 0. Summary

Keeper context compaction has a single mechanism to reduce a conversation that
has grown past the provider's context window: ask an LLM for a per-message
keep/drop/summarize **plan**, gated on the provider supporting native
`json_schema` output. When that plan cannot be produced — no schema-capable
model configured, the one capable model rate-limited, or the returned plan
invalid — the reactive overflow path has **no fallback that reduces size**. It
requeues the same over-limit context, which overflows again, which retries
compaction, which fails again. The keeper deadlocks (death spiral). The specific
failure reason is not surfaced as keeper status, so an operator sees a stuck
keeper with no cause.

This is one design failure with three visible symptoms (blind, model-restricted,
over-constrained). The root is that **context-size reduction is coupled to
semantic summarization** and both are gated on one rate-limited external model,
with no deterministic floor.

The fix, in priority order:

1. **Deterministic structural floor** — when no LLM plan is available or valid,
   produce a deterministic keep/drop plan over the existing
   `Keeper_compaction_unit` structural units (keep system + most-recent K units,
   elide the middle behind one marker unit). Compaction can then always reduce
   size. This breaks the spiral. The floor is a *plan source*, not a bypass: it
   flows through the same validation and commit path as the LLM plan.
2. **Typed compaction outcome** persisted to `compaction_rt` and surfaced in the
   dashboard, replacing the current "reason is dropped / only a generic
   `Turn_overflow_failure` is recorded" behavior.
3. **De-couple model gating** — the structural reduction no longer needs a
   schema-capable model at all; the LLM is used only to *improve* the summary
   when one is available. Widening schema-capable candidates becomes an
   optimization, not a liveness requirement. (Overlaps RFC-0042 / issue #25051.)

## 1. Problem (evidence)

### 1.1 The reactive overflow path has no size-reducing fallback

Path (`lib/keeper/keeper_unified_turn.ml`):

- Provider returns a context-overflow error → `recover_provider_context_overflow_in_lane`
  dispatches `Compaction_started`, then calls
  `recover_latest_checkpoint_for_compaction`.
- If that returns `Error _` (any `compaction_rejection`), the code takes
  `retry_after_started` → `record_overflow_failure` +
  `release_failed_lifecycle (Compaction_failed)` → returns
  `Provider_overflow_retry_without_checkpoint`.
- The consumer (`keeper_unified_turn.ml:309`) maps that to
  `Requeue_after_context_compaction` — **the source stimulus is requeued with
  the same, still-over-limit context.**

So on any compaction rejection the next cycle re-overflows and re-attempts the
same compaction. Nothing between the failures reduces context size. When the
cause is persistent (the one schema-capable model is weekly-rate-limited), the
loop does not terminate. This matches the live observation of a keeper emitting
`compaction_started` repeatedly with zero `compaction_completed`
(#25062 track; project memory 2026-07-18).

### 1.2 Size reduction is coupled to semantic summarization

The only plan source is `Keeper_compaction_llm_summarizer`. Its
`eligible_candidate` drops any runtime whose provider fails
`plan_schema_supported` (native `json_schema`):

```
if not (plan_schema_supported provider_cfg) then ( warn "...does not support the
compaction plan schema"; None ) else Some { runtime_id; provider_cfg }
```

`compaction_runtime_ids` offers `[Structured_judge lane; keeper's own Keeper_chat
lane]`, but the keeper's chat runtime (e.g. `glm-*`, `deepseek-*`) fails the
schema gate, so in practice the only eligible candidate is the structured-judge
model (`minimax-*-native-structured`). One model, with a weekly quota, is the
sole guarantor of a liveness-critical operation. This is the
single-dependency-stop → total-stop shape.

The coupling is the deeper issue: deciding **which** units to keep is a purely
structural operation (keep recent, drop old, never split a `Closed_tool_cycle`),
and needs no LLM. Only *summarizing the dropped span* needs a capable model.
The current design entangles the two, so the always-required operation inherits
the availability of the optional one.

### 1.3 The failure reason is not observable as status

- `compaction_rt.last_decision` is written only on the pre-check decisions
  (`Not_requested`, no-checkpoint) in `keeper_post_turn.ml:400-460`. The actual
  attempt returns `Error (Compaction_rejected reason)` (`:599`) and that reason
  is **never written back** to `compaction_rt`.
- The reactive path records only a generic
  `Keeper_registry.Turn_overflow_failure` (`record_overflow_failure`,
  `keeper_turn_runtime_budget.ml:411`); the specific `compaction_rejection`
  survives only in the turn manifest/trace, not in status.
- The dashboard normalizer (`dashboard/src/keeper-store-normalize.ts`) enumerates
  only success-side compaction fields and reads neither `last_decision` nor any
  failure field.

Net: 26/28 recent compaction attempts failed, and the operator has no
status-level signal for why. The manual-compaction tool path *does* return a
structured error to its caller (`keeper_tool_surface.compaction_recovery_error_data`),
but the reactive path — the one that matters for the spiral — does not persist it.

### 1.4 Why the previous attempt (PR #25232) is not this fix

PR #25232 tried to reduce *how much* accumulates by stamping/superseding
world-state user messages; it was a no-op because masc metadata cannot cross the
OAS conversation boundary (see the world-state-channel-split RFC). That work is
upstream (reduce accumulation); **this** RFC is downstream (guarantee reduction
when the window is already exceeded). They are complementary, not alternatives.

## 2. Design

### 2.1 A deterministic structural plan as a floor

`Keeper_compaction_unit` already segments the checkpoint into ordered units
(`Ordinary_message`, `Closed_tool_cycle`). The LLM summarizer produces a
keep/drop/summarize decision over these units; the policy validates it
(`Structurally_unchanged`, `Checkpoint_not_reduced`) and commits it.

Add a **deterministic reduction** over the same units (implemented in PR #25281
as `deterministic_floor_requested` in `keeper_compact_policy.ml`):

- Protect a **head window** (`floor_protected_head_units`, the conversation's
  setup: system prompt / first goal) and a **tail window**
  (`floor_protected_tail_units`, recent context).
- Drop whole units from the **middle** — but only `Ordinary_message` units whose
  role is `User` or `Assistant`. `Closed_tool_cycle` and `System` units are never
  dropped (see §2.1.1). Because it drops User messages, it targets the dominant
  accumulation (the world-state `User` block), not just Assistant text — which is
  what the LLM path is limited to.
- Whole-unit drops keep tool cycles intact (a `Closed_tool_cycle` is one unit),
  so a `tool_result` is never orphaned.
- No summary is produced — this is lossy (drop, not summarize), a last resort
  when the LLM is unavailable. #25194 (before-state preservation) is the
  complement for recovering the dropped span; a marker unit naming the elided
  span is a possible follow-up.

The result is the **same `requested_compaction`** the LLM path produces (message
list + selected-runtime-id + summarized/dropped counts), so it flows through the
identical evidence + reduction-guard + `commit_prepared_after_save` path. It is
an alternative reduction source, not a new bypass — blast radius is the
plan-production boundary only.

### 2.1.1 The tool-count invariant constrains what the floor may drop

`Keeper_compaction_evidence.create` (`lib/keeper_compaction_evidence/…ml:200-209`)
rejects any compaction where `after_tool_use_count <> before_tool_use_count` or
`after_tool_result_count <> before_tool_result_count` (`Invalid_transition`). The
LLM path only ever touches eligible units (pure-text `Assistant` messages with no
tool blocks), so its tool counts are invariant by construction. The floor must
honour the same invariant, so it **cannot drop `Closed_tool_cycle` units**
(that would reduce the tool counts and be rejected as
`Invalid_structural_evidence`). Since `Keeper_compaction_unit.partition` groups
every tool cycle into a `Closed_tool_cycle`, an `Ordinary_message` carries no tool
blocks, so dropping User/Assistant ordinary units keeps the tool counts invariant
and passes evidence. This is why the floor's drop set is exactly
"middle `Ordinary_message` User/Assistant units".

### 2.1.2 Why positional head protection is required

`partition` only protects a trailing *open* tool cycle as `protected_suffix`; the
entire rest of the conversation, **including the leading system prompt / first
goal at index 0**, lands in `closed_prefix`. A naive "drop the oldest units"
floor would therefore drop the foundational setup. The head window protects it
positionally without needing role classification of the leading messages.

### 2.2 Where the floor engages

Resolution order inside `requested_messages` (`keeper_compact_policy.ml`), gated
by the exhaustive `floor_should_engage` classifier:

1. Try the LLM plan (existing path).
2. Engage the floor when the LLM path yields a "no usable reduction" reject:
   `Runtime_identity_unavailable | Summarizer_unavailable |
   Plan_provider_unavailable | Invalid_compaction_plan | No_eligible_history`.
   `No_eligible_history` is included deliberately: the LLM cannot summarize a
   conversation with no eligible Assistant-text units, but the floor can still
   drop middle User units (exactly the world-state-bloat case).
3. Do **not** engage the floor on a *successful* LLM decision that kept
   everything (`Structurally_unchanged`) or on a genuine structural error
   (`Invalid_structure`, `Checkpoint_not_reduced`, `Invalid_structural_evidence`)
   — these are respected, not overridden. `floor_should_engage` is an exhaustive
   match over `compaction_rejection`, so a new reject variant forces a
   compile-time decision.
4. If the floor finds no middle span to drop (`total <= head + tail`, or the
   middle is all tool cycles / System units), it returns `None` and the original
   LLM reject stands. The downstream reduction guards
   (`Structurally_unchanged` / `Checkpoint_not_reduced`) still reject a floor
   that fails to shrink the checkpoint. Either way the outcome is surfaced
   (§2.3), never spun on.

This removes the deadlock for the case that must not fail closed (a capable model
is temporarily unavailable) while never manufacturing a fake reduction.

### 2.3 Typed compaction outcome (observability)

Introduce a typed outcome recorded to `compaction_rt` on **every** attempt,
reactive or manual:

```
type compaction_outcome =
  | Applied_llm of { saved_tokens : int }
  | Applied_floor of { saved_tokens : int; elided_units : int }   (* degraded *)
  | Rejected of compaction_rejection                              (* terminal, real *)
  | Failed_terminal of { reason : compaction_rejection }          (* floor also could not reduce *)
```

- `keeper_post_turn` / the reactive path write this to
  `compaction_rt.last_outcome` (not just the pre-check `last_decision`).
- `keeper_status` emits it.
- `keeper-store-normalize.ts` reads it and the dashboard renders
  success / degraded-floor / terminal-reason distinctly.

This is a legitimate observability fix, not telemetry-as-fix: the failure states
are real and are *already* the correct behavior; the defect is that they are not
representable in status. The counter is not the fix — the floor (§2.1) is; the
outcome field just makes the floor's behavior legible.

### 2.4 Model gating becomes an optimization

With §2.1 in place, a schema-capable model is no longer required for liveness.
The remaining work on candidate breadth (RFC-0042 / #25051: let operators
configure additional schema-capable structured-judge lanes, and reconsider the
hard native-`json_schema` gate vs the unused `apply_schema_or_prompt_tier`
prompt-tier path) improves *summary quality and frequency of the good path*, but
no longer gates whether the keeper can survive an overflow. This RFC does not
re-decide the gate; it removes the gate from the liveness path so #25051 can be
decided on quality grounds, not liveness pressure.

## 3. Relationship to other tracks

| Track | Relationship |
|---|---|
| world-state-observation-channel-split RFC (#25246) | Upstream: reduces accumulation so overflow is rarer. This RFC: guarantees recovery once overflow happens. |
| RFC-0042 / #25051 (compaction runtime coupling, native-schema gate) | This RFC removes the *liveness* dependency on that gate; #25051 remains for summary-quality/candidate breadth. No duplication. |
| #25266 (structured-output wire format) | Complementary *quality* fix: masc always sends `json_schema` strict, so only `ollama`-native (minimax) qualifies; sending `json_object` to json_object-only providers (GLM/DeepSeek/Kimi) would widen the good path. That widens *which models can plan*; this RFC guarantees liveness when *none* can. |
| #25062 (compaction death spiral, live) | This RFC is the structural fix for that spiral. |
| #25194 (pre-compaction before-state preservation) | The floor is lossy (it drops the middle span without a summary); #25194 preserves that span for recovery. A marker unit naming the elided span (§6) would reference #25194's store. |

## 4. Phases

1. **PR-1 (observability, harness-first)** — **DONE, merged as #25270.** Shipped
   option (a): a `Keeper_registry.set_compaction_decision` meta-updater, stamped
   from the reactive `record_overflow_failure` path onto the existing
   `compaction_rt.last_decision` (`provider_overflow_recovery_failed: <reason>`),
   plus the dashboard read/render of `last_compaction_decision`. The post_turn
   `Rejected` stamp (`keeper_post_turn.ml:599`) and the richer typed
   `compaction_outcome` of §2.3 were deferred — the floor (#25281) makes itself
   observable through the sentinel `selected_runtime_id = "deterministic_floor"`
   (which flows to evidence/manifest) and, on failure, through this same
   `last_decision`.

   **Plumbing sub-decision (found during scoping — do not re-derive):** the
   reactive path (`record_overflow_failure`, `keeper_turn_runtime_budget.ml:411`)
   updates the registry via `Keeper_registry.set_failure_reason` (a generic
   `Turn_overflow_failure` enum) and cannot currently write
   `compaction_rt.last_decision`, because the registry updaters
   (`update_entry_if_registered` + `update_current_turn`) mutate only the
   turn-observation record; the meta's `compaction_rt` is persisted wholesale by
   the turn lifecycle (post_turn returns `updated_meta`; its caller persists).
   The existing surfaced string fields are unsuitable: `last_error` in status is
   `sandbox_last_error` (sandbox-specific — overloading it conflates concepts).
   So PR-1 must add one of: (a) a registry meta-updater
   `set_compaction_decision ~base_path name decision` that does
   `update_entry_… (map_compaction_rt (set last_decision))`, callable from the
   reactive path; or (b) a dedicated `last_compaction_error : string option`
   registry field + status emission. (a) reuses the already-serialized
   `last_decision` (`keeper_meta_json.ml:57`, `keeper_status.ml:169`,
   `keeper-store-normalize.ts` needs the read); (b) keeps decision vs error
   distinct. Recommend (a) for the reactive stamp plus writing the post_turn
   `Rejected` reason (`keeper_post_turn.ml:599`) to the same field, so both
   attempt sites converge on one observable. The frontend read
   (`keeper-store-normalize.ts` already emits `last_compaction_decision` from
   the backend but the normalizer does not consume it) is a small addition.
2. **PR-2 (deterministic floor)** — **implemented as #25281 (in review).**
   `deterministic_floor_requested` over `Keeper_compaction_unit`, engaged per
   §2.2, dropping middle `Ordinary_message` User/Assistant units while preserving
   tool cycles and System units (§2.1.1). Tests pin: middle drop with head/tail
   protection, protected-suffix preservation, no-op without a middle span, and
   tool-cycle/System preservation. The `Applied_floor` typed outcome was folded
   into the sentinel `selected_runtime_id`; a live acceptance test (a keeper with
   the structured-judge lane forced unavailable no longer loops on
   `compaction_started`) is the remaining validation once deployed.
3. **PR-3 (candidate breadth, coordinate with #25051)**: only if #25051 has not
   already covered it — operator-configurable schema-capable lanes. Quality, not
   liveness.

## 5. Alternatives rejected

- **Weaken the native-`json_schema` gate to admit weak models** (schema-classifier
  loosening): rejected. The LLM plan needs index-accurate structure; weak models
  produce more `invalid_compaction_plan`, not fewer failures. The floor solves
  liveness without weakening the good-path gate.
- **Add a retry cap / cooldown on the overflow loop**: rejected as a
  cap/cooldown symptom-suppressant (CLAUDE.md workaround bar). A cap stops the
  spin but leaves the keeper unable to make progress — the context is still over
  limit. The floor makes progress; the cap only makes the failure quieter.
- **Counter of dropped compactions**: rejected as telemetry-as-fix. §2.3's
  outcome field exists to make the *floor's* behavior legible, not to substitute
  a metric for a fix.

## 6. Open questions

- `K` (`compaction_floor_keep_units`) default and whether it should be
  token-budget-derived rather than a fixed unit count.
- Should `Applied_floor` immediately schedule a *deferred* LLM re-compaction when
  the capable model returns (upgrade the floor's crude elision to a real
  summary), or is the floor result durable until the next natural trigger?
- Marker-unit persistence: the elided span must be recoverable (#25194); confirm
  the marker's `<ref>` survives checkpoint round-trips and history `Drop_line`
  classification.
