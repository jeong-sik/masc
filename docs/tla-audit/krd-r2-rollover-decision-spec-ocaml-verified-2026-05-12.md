# KRD R-2 — KeeperRolloverDecision.tla ↔ OCaml: mapping verified, one scope gap + one missing reverse-citation (first-entry audit)

**Date**: 2026-05-12 · **Iteration**: 75 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: R (first entry)
**Spec**: `specs/keeper-state-machine/KeeperRolloverDecision.tla` (165 LOC, 7 vars, bug-model paired)
**OCaml**: `lib/keeper/keeper_rollover.ml` (349 LOC) · `lib/keeper/keeper_rollover.mli` (78 LOC)
**Verdict**: **clean** — the spec's `OCaml ↔ TLA+ mapping` table is accurate, the decision CASE matches `classify_rollover_gate` arm-for-arm, the provider-opacity property is enforced by a purely-typed predicate (zero substring matches in the file), and both `.cfg` / `-buggy.cfg` exist. Two doc/model-completeness nits, both fixed in this PR:

1. **Scope gap** — the OCaml `signal_gate` is a *disjunction of two* overflow signals; the spec models only one (the historical `last_blocker_info`+`Proactive_error` path). Fixed by adding a "Spec scope" note to the spec preamble (R-2.a — 16th honest-doc datapoint: comment-only, TLC not re-run).
2. **One-directional cross-ref** — the spec cites `keeper_rollover.ml:classify_rollover_gate`, but `keeper_rollover.ml`'s "Spec navigation" block cites only `KeeperGenerationLineage.tla` (a different aspect of the same module); code search for `KeeperRolloverDecision` lands nowhere in `lib/`. Fixed by extending the `classify_rollover_gate` doc comment with a reverse-citation.

## Cross-checks (all pass)

| Spec element | OCaml | Status |
|---|---|---|
| `autoHandoff` / `cooldownElapsed` (BOOLEAN) | `classify_rollover_gate ~auto_handoff ~cooldown_elapsed` | ✓ exact named args |
| `ratioGate` (BOOLEAN) | `let ratio_gate = ratio >= handoff_threshold` | ✓ — spec's "ratio >= handoff_threshold" semantic note matches |
| `lastOutcome` ∈ {`proactive_error`,`proactive_silent`,`proactive_text`} | `last_outcome : proactive_cycle_outcome` (`Proactive_text_response \| Proactive_silent \| Proactive_error` — 3 inhabited; the runtime type also carries `Proactive_text_*` variants the spec folds into `proactive_text`) | ✓ — abstract symbol set, no provider semantics |
| `lastBlockerClass` ∈ `BlockerClasses ∪ {"none"}` (abstract `"overflow"` / `"non_overflow"`) | `last_blocker_info : blocker_info option` → `blocker_class_indicates_overflow klass` | ✓ — spec deliberately models the typed class as opaque symbols to enforce opacity at the model-checking level |
| `SignalFires(o,k) == o = "proactive_error" /\ k = "overflow"` | `last_outcome = Proactive_error && info_indicates_overflow last_blocker_info` | ✓ for the modelled disjunct (see scope gap below) |
| `ComputeDecision`: `~ah→skip_disabled`; `~ce→skip_cooldown`; `rg/\sig→go_both`; `rg/\~sig→go_ratio`; `~rg/\sig→go_signal`; OTHER→`skip_below` | `if not auto_handoff then Skip "auto_handoff_disabled" else if not cooldown_elapsed then Skip "cooldown" else match ratio_gate, signal_gate with \| true,true -> Go "ratio+signal" \| false,true -> Go "persistent_overflow_blocker" \| true,false -> Go "ratio" \| false,false -> Skip "below_thresholds"` | ✓ — arm-for-arm; spec's `decision` symbols ↔ OCaml's `Skip`/`Go` reason strings (semantic, not literal — mapping table line 13 says `Skip(reason) \| Go(reason)`) |
| `blocker_class_indicates_overflow` is **purely typed** — "substring matching at this layer is forbidden" (preamble §Architectural invariant) | `let blocker_class_indicates_overflow (klass : blocker_class) : bool = match klass with \| Sdk_token_budget_exceeded -> true \| ... -> false` — exhaustive variant match, no `String.starts_with` / `contains` / `is_substring` / `"overflow"` literal anywhere in the file (`rg` → 0 matches) | ✓ — the SDK boundary (`Keeper_status_bridge`) is the sole wire→typed adapter, exactly as the preamble asserts |
| `SignalGateOverflowOnly` invariant (signal half fires only on `"overflow"`) | holds for **both** OCaml disjuncts — they call the same `info_indicates_overflow` ⇒ `blocker_class_indicates_overflow`; no class-specific bypass | ✓ — invariant is a faithful model of the architectural property even though it only names one disjunct |
| `SpecBuggy` / `ComputeDecisionBuggy` (signal fires on `outcome="proactive_error" /\ klass /= "none"` — any non-none class, mirroring the historical substring drift) | not present in OCaml — the runtime gate is class-typed, never "any non-empty class" | ✓ — runtime does not exhibit the modelled bug |
| `.cfg` / `-buggy.cfg` | `KeeperRolloverDecision.cfg` + `KeeperRolloverDecision-buggy.cfg` both present | ✓ |

## The scope gap (LOW — model completeness, not a safety hole)

`classify_rollover_gate` (lines 137-162) computes:

```ocaml
let current_turn_signal = info_indicates_overflow current_turn_blocker_info in
let signal_gate =
  current_turn_signal
  || (last_outcome = Proactive_error && info_indicates_overflow last_blocker_info)
in
```

That is **two** overflow signals OR'd together:

- **(a)** `?current_turn_blocker_info` — the *in-flight* turn's blocker. Fires regardless of `last_outcome`. Optional named arg, defaults to `None`.
- **(b)** `last_blocker_info` — the *previous* turn's blocker, gated on `last_outcome = Proactive_error`.

`KeeperRolloverDecision.tla` models only **(b)**: `SignalFires(outcome, klass) == outcome = "proactive_error" /\ klass = "overflow"`, and the `Next` action picks fresh `(lastOutcome, lastBlockerClass)` only — there is no `currentTurnBlockerClass` variable, and the `OCaml ↔ TLA+ mapping` table doesn't mention `current_turn_blocker_info`.

**Why this is benign**: both disjuncts route through the *same* typed predicate `blocker_class_indicates_overflow` over the *same* `blocker_class` set. There is no class-specific behaviour on path (a) that (b) lacks. So `SignalGateOverflowOnly` — "the signal half fires only when the class is `overflow`" — is true of the real runtime even though the spec only names one of the two ways the signal half can fire. The spec is a *partial but sound* model: it under-approximates the trigger conditions, never over-approximates the safety guarantee.

**Fix-PR (DONE — this PR, R-2.a)**: added to the spec preamble (after the mapping table) a "Spec scope" note documenting the two-disjunct shape and stating the invariant covers (a) by construction; flagged that if (a) ever grows class-specific behaviour it must be added as a second `SignalFires` disjunct. Comment-only — TLC not re-run (16th honest-doc datapoint; same handling as iters 64/67/69 honest-doc spec edits).

## The missing reverse-citation (LOW — navigability)

The spec preamble cites the OCaml three times (`classify_rollover_gate`, `blocker_class_indicates_overflow`, `rollover_gate_decision`). The OCaml file *does* have a "Spec navigation (OCaml -> TLA+)" block — but it points at `KeeperGenerationLineage.tla` (the *handoff-lineage* aspect of `keeper_rollover.ml`), not at `KeeperRolloverDecision.tla` (the *gate-decision* aspect). So a `grep KeeperRolloverDecision lib/` returns nothing — the reverse leg of the bidirectional cross-ref is absent.

**Fix-PR (DONE — this PR)**: extended the `classify_rollover_gate` doc comment with a localized reverse-citation (`Spec mirror: [specs/keeper-state-machine/KeeperRolloverDecision.tla] models this gate; SignalGateOverflowOnly is the safety invariant; ...; reverse-citation so code search for "KeeperRolloverDecision" lands here.`). Localized rather than in the file header because the gate-decision concern is distinct from the lineage concern the header block already covers.

## Sub-class placement

This is **first-entry sub-class 1 (coverage gap)** in the mild form — the spec is sound and the cross-checks pass, the "gap" is that the spec's `Next` action under-models the OCaml's two-source signal disjunction. It is *not* sub-class 2 (drift — nothing has drifted), not 3 (cross-spec staleness), not 9 (spec-banner-lags-runtime — the banner here is accurate for what it models). Both fixes are doc-only; no behaviour, no TLC re-run, no new test (the architectural invariant is already exercised by the spec's own `SpecBuggy` / `SignalGateOverflowOnly` pair, which TLC checks in CI).
