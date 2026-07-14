# RFC-0258: Adversarial Review — Grounded Verdict & Unified Verdict→Action Routing

**Status**: Draft
**Date**: 2026-06-18
**Verified against base main**: `7a5cc97531` (post-#21401 merge)
**Builds on**: [RFC-0042](./RFC-0042-keeper-terminal-code-closed-sum.md) (no-string-classifier lineage), [RFC-0199](./RFC-0199-evidence-driven-auto-approval.md) (evidence-driven verdict replaces human bottleneck — same philosophy, different domain)
**Related**: PR #21401 `feat(keeper): adversarial review verdict + author wake-on-fail (PoC)`; Anti_rationalization (#3067, cross-model adversarial completion gate)
**Number note**: this RFC was first drafted as `0256`, which collided with PR #21471 (`RFC-0256-mutex-protect-migration.md`, an unrelated topic — not a multi-phase share). It was then renamed to `0257`, but current main now contains `RFC-0257-per-keeper-memory-execution-lane.md`. This RFC therefore takes the queue-next free number `0258` and advances the ledger to `0259`. This collision is itself an instance of the `.next-number` read-not-reserve race, which the meta-fix in RFC-0078 (number reservation ledger) is meant to close at merge time.

## 1. Summary

Adversarial review in masc is not one feature — it is **four modules emitting the same `Verifier_core.verdict` but each hardcoding its own trigger and its own post-verdict action**. PR #21401 proposes a fifth slice (verdict→author-wake) as an isolated module. Adding it as-is widens an already-fragmented surface and re-derives verdict→action routing a fifth time.

This RFC proposes two coupled changes:

1. **Grounded verdict** — a reviewer's `Fail` (or `Warn`) is only honoured as a *blocking/wake-triggering* verdict when it carries machine-checkable evidence (`path` + optional `line` + verbatim `quote`). An ungrounded `Fail` is demoted to `Warn` (visible, but no gate, no wake). This is the type-level answer to the confabulation failure mode that has repeatedly produced plausible-but-fabricated adversarial findings.

2. **Unified verdict→action router** — a single deterministic `Verdict_router` that maps `(grounded_verdict, trigger_context) → action ∈ {Gate_block | Advisory | Wake of identity}`. The four existing reviewers keep their *triggers* but route their *actions* through one place. PR #21401's novelty (the `Wake` branch) becomes a router case, not a new module.

The boundary stays exactly where the PoC put it: **judgment = LLM, routing = deterministic**. This RFC only hardens *what counts as a judgment* and *unifies where routing lives*.

## 2. Context & problem

### 2.1 The four verdict surfaces (verified)

> **Update (2026-07-14, owner decision)**: the structural `Adversarial_eval` surface (row 3 below) and its `masc_keeper_adversarial_review` keeper tool have been **removed** from the codebase (`lib/cdal/` deleted). It was advisory-only and never adopted; the prompt-based grounded-LLM reviewers are the only adversarial reviewers going forward. The row is retained below as historical context for the design, not as a live surface — treat later mentions of `Adversarial_eval` in §4.3 / §8 the same way.

| Module | Trigger | Action | Wiring |
|---|---|---|---|
| `Verifier_oas` (`lib/verifier_oas.ml:73-113`, `.mli:25` `handle_pre_tool_use`) | before action (PreToolUse) | **gate** | wired |
| `Anti_rationalization` (`lib/task/anti_rationalization.mli:1-16,78`) | on completion | **gate** | wired into `lib/task/task.ml`, `tool_task_handlers.ml` |
| `Adversarial_eval` (`lib/cdal/adversarial_eval.ml`) via tool `masc_keeper_adversarial_review` | post diff | **advisory only — not a gate** | **removed 2026-07-14** (retired; see note above) |
| PoC #21401 `Keeper_adversarial_review` (`act_on_verdict` at `keeper_adversarial_review.ml:156`, `wake_author:113`) | on completion | **wake author** | **unwired** |

All four share `Verifier_core.verdict` (`lib/verifier_core.mli:21-24`). All four use the generic engine `run_named_with_masc_tools` (`lib/keeper/keeper_turn_driver_wrappers.ml:157`). The PoC's own `.ml` comment states it "Mirrors `Verifier_oas.verify`".

**Observation**: the PoC's trigger (on completion) is identical to `Anti_rationalization`'s; only the action differs (wake vs gate). It is not a new axis — it is a new cell in an existing row.

### 2.2 The real risk this must address: reviewers confabulate

The adversarial reviewer itself hallucinates. During #21401 review cleanup, an auto-generated adversarial critique asserted OCaml-impossible failures ("Eio multi-domain writes a Variant constructor non-atomically", "`Match_failure` from partial type writes"); the merged PR body was later cleaned, so this is historical review evidence rather than a current PR-body claim. A separate documented case: a keeper adversarial review narrated *another PR's diff* as this PR's, with zero diff-matched citations.

Consequence: **adding more reviewers or more wake triggers without grounding is an amplifier that pushes wrong findings into rework loops faster.** The 13+ telemetry-as-fix / string-classifier workaround precedents (CLAUDE.md §워크어라운드) show the failure compounds once it lands. Grounding must be a *precondition of a blocking verdict*, not a prompt-level suggestion.

The PoC already asks for `path:line` grounding — but only in the prompt (`config/prompts/verification.adversarial_review.md`). A prompt is advisory; the model can ignore it and the verdict is still honoured. This RFC moves grounding from prompt to type.

## 3. Premise: the verdict type is schema-locked

`lib/verifier_core.mli:21-24`:

```ocaml
type verdict = Pass | Warn of string | Fail of string
```

The `.mli` (Issue #8436) constrains this hard: the `report_verdict` MCP schema assumes **payload-free constructor names** (`PASS`/`WARN`/`FAIL`), `report_verdict_schema` (`:59`) enumerates them, and `test_types.ml` asserts every variant appears in `valid_verdict_strings`. **Restructuring the variant payload** (e.g. `Fail of { reason; evidence }`) breaks the schema enum assumption, `verdict_to_string`/`verdict_constructor_name`/`parse_verdict`/`parse_verdict_from_json`, and all four consumers simultaneously.

Therefore grounding must be added **without changing the `verdict` variant shape**.

## 4. Design

### 4.1 `evidence` as an additive schema field (verdict enum unchanged)

`report_verdict_schema` gains an optional `evidence` array; the `verdict` enum is untouched, preserving #8436:

```jsonc
// report_verdict args (verdict enum unchanged; evidence is new + optional)
{ "verdict": "FAIL",
  "reason": "ratelimit retry loop never resets the backoff counter",
  "evidence": [ { "path": "lib/foo.ml", "line": 88, "quote": "let backoff = ref 1 (* never reset *)" } ] }
```

New pure types in `Verifier_core` (no variant added, so #8436 holds):

```ocaml
type grounded_ref = {
  path  : string;        (* repo-relative path *)
  line  : int option;    (* 1-based; None = file-level *)
  quote : string;        (* verbatim excerpt being cited *)
}

type grounded_verdict = private {
  verdict  : verdict;
  evidence : grounded_ref list;
}
```

### 4.2 Smart constructor — ungrounded blocking verdict is unrepresentable

```ocaml
(** [Pass] needs no evidence. [Warn]/[Fail] with empty evidence are
    REFUSED — the caller must re-prompt the reviewer once for grounding.
    Parse, don't validate: a [grounded_verdict] cannot exist in a
    blocking shape without >=1 grounded_ref. *)
val grounded_of : verdict -> grounded_ref list -> (grounded_verdict, string) result
```

Policy (the demotion rule, deterministic):

- `Pass` → always valid (evidence ignored).
- `Fail`/`Warn` + `≥1` evidence → valid grounded verdict.
- `Fail`/`Warn` + empty evidence → **`Error`**. The caller (`run_review`) re-prompts the reviewer exactly once ("a FAIL/WARN must cite ≥1 path:line you inspected"). If still empty → **demote to `Warn` with a synthetic reason `"ungrounded: <original reason>"`**. A demoted `Warn` never gates and never wakes.

This is the crux: **no `Fail` blocks or wakes unless the reviewer cited evidence it can be held to.** Demotion (not silent drop) keeps the signal visible — it is the opposite of telemetry-as-fix: the human/operator still sees the concern, but the *automated consequence* (gate/wake) requires grounding.

> WORKAROUND-NOTE: demotion-to-Warn is a deliberate floor, not a symptom suppressor — it is the conservative action when grounding is absent (refuse to act on unverifiable input), per CLAUDE.md "Unknown → error, not permissive default". It does not hide the verdict; it withholds the irreversible action.

### 4.3 Unified `Verdict_router`

```ocaml
type trigger = Pre_tool_use | On_completion | Post_diff
type action  = Gate_block of string | Advisory of string | Wake of { author : identity; reason : string }

(** Deterministic. No string match on reason. Routing depends only on
    (verdict tag, trigger, grounding presence). *)
val route : grounded_verdict -> trigger:trigger -> author:identity option -> action list
```

Routing matrix (deterministic, exhaustive — no `_ ->` catch-all, per RFC-0042 lineage):

| verdict | trigger | action |
|---|---|---|
| `Pass` | any | `[]` |
| `Warn` (grounded or demoted) | any | `[Advisory]` |
| `Fail` (grounded) | `Pre_tool_use` | `[Gate_block]` |
| `Fail` (grounded) | `On_completion` | `[Wake author]` (PoC's case) + `[Advisory]` |
| `Fail` (grounded) | `Post_diff` | `[Advisory]` (current `Adversarial_eval` behaviour preserved) |

The four reviewers keep their triggers; each calls `Verdict_router.route` instead of hand-coding its action. PR #21401's `act_on_verdict` (`:156`) becomes the `On_completion + Fail` case. Wake still uses `Keeper_external_attention.record` (`lib/keeper/keeper_external_attention.mli:95,125`; existing caller `server_discord_in_process_gateway.ml` is the only other one today).

## 5. Migration & scope

Incremental, compiler-forced, no big-bang:

1. **P1 — types only**: add `grounded_ref`, `grounded_verdict`, `grounded_of`, extend `report_verdict_schema` + `parse_verdict_from_json` to read `evidence`. No behaviour change; existing parse path keeps working (evidence defaults to `[]`, so old reviewers produce demoted `Warn` on `Fail` until they emit evidence). Ship behind no flag — it is purely additive.
2. **P2 — router**: add `Verdict_router` with its exhaustive verdict×trigger matrix and table-driven test (§6). No reviewer is migrated in this step: the structural `Adversarial_eval` advisory surface that this RFC originally used to prove the seam has been removed (owner decision, 2026-07-14 — see §2.1), so the router's own exhaustive-match test proves the seam. The first live migration lands in P3. The prompt-based grounded-LLM reviewers are the only adversarial-review surfaces going forward.
3. **P3 — PoC absorption**: re-target PR #21401's wake as the `On_completion + Fail (grounded)` router case. Decide: fold into `Anti_rationalization` (one row, already wired) **or** keep `Keeper_adversarial_review` as a thin trigger that delegates to the router. (Open question — §8.)
4. **P4 — gate migration**: `Verifier_oas`, `Anti_rationalization` route through `Verdict_router`. This changes the live gate path → feature-flagged + DET/NDT contract reviewed.

Out of scope: the PostToolUse-hook deposit slice the PoC names as "next" — that is a trigger, and triggers are unaffected by this RFC (they just feed the router).

## 6. Verification

- **P1**: `grounded_of (Fail "x") []` = `Error`; `grounded_of (Fail "x") [ref]` = `Ok`; `grounded_of Pass []` = `Ok`. `parse_verdict_from_json` round-trips evidence. `test_types.ml` still green (no new variant).
- **Router**: table-driven test of the full matrix; assert no catch-all by exhaustive match (compile-time, RFC-0042 style).
- **Confabulation guard test**: a `Fail` with a `quote` that does not occur at `path:line` is rejected at grounding-check (a deterministic file read in the router's pre-action validation, *not* an LLM call) → demoted. This is the one place a cheap deterministic check is legitimate: it verifies the citation exists, it does not judge the finding.
- **TLA+ (optional, P4)**: model "ungrounded Fail triggers wake" as a `BugAction`; invariant `WakeRequiresGroundedFail` must be violated by `NextBuggy` and held by `Next` (per CLAUDE.md TLA+ bug-model pattern).

## 7. Trade-offs

- **Cost**: every blocking verdict now requires the reviewer to emit ≥1 citation and a deterministic file-read to confirm it exists. Adds one re-prompt in the worst case (ungrounded first attempt). Verdicts that legitimately have no single line (architectural concerns) are forced to `Warn`, not `Fail` — arguably correct (architecture objections shouldn't auto-gate), but some reviewers may find it restrictive.
- **Does not fix**: the reviewer can still cite a *real* line and draw a *wrong* conclusion from it (grounding ≠ correctness). This RFC kills fabricated-citation findings, not wrong-but-grounded ones. Those remain a human/second-reviewer concern.
- **Alternative rejected — `Fail of {reason;evidence}`**: cleanest in isolation but breaks #8436 schema-enum + 4 consumers + regression test at once (§3). Rejected for blast radius.
- **Alternative rejected — leave grounding in the prompt**: status quo; the PoC already does this and it is advisory-only, which is exactly the gap (§2.2).

## 8. Open questions

1. **P3 placement**: fold the wake branch into `Anti_rationalization` (collapses to one on-completion surface, fewest modules) vs keep `Keeper_adversarial_review` as a thin router-delegating trigger (preserves the PoC's prompt isolation). Recommendation: fold, unless the adversarial prompt must stay isolated from the completion-notes prompt for eval reasons.
2. **Name collision**: main already has a `masc_keeper_adversarial_review` tool (`Adversarial_eval`, advisory). PR #21401's module is `keeper_adversarial_review`. If P3 keeps a module, it must be renamed to avoid two near-identical names for different behaviours.
3. **Demotion vs hard-refuse**: should an ungrounded `Fail` demote to `Warn` (visible, no action) or hard-error back to the reviewer loop until grounded? This RFC picks demote-after-one-retry to bound cost; a stricter mode could be a flag.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
