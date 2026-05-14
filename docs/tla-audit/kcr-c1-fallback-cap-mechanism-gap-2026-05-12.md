# KCR Phase C-1 Audit — Fallback Cap Mechanism Mismatch

**Iteration**: 22 (/loop FSM/TLA+/OCaml drift hunt — first KCR entry)
**Date**: 2026-05-12
**Spec**: `specs/keeper-state-machine/KeeperCascadeRouting.tla` (366 LOC)
**OCaml**: `lib/keeper/keeper_cascade_selector.ml` (`select_item_for_turn`)
**Risk**: MID — both mechanisms terminate fallback in *practice*, but they cap by different metrics, so TLA+ `FallbackCountBounded` is enforced by a side-effect, not by a faithful OCaml counterpart.
**Type**: Audit-only (no code change in this PR).

## Spec context

`KeeperCascadeRouting.tla` models cascade fallback with an explicit
counter:

```tla
VARIABLES
    ...
    fallback_count,        \* keeper → Nat
    group_path,            \* keeper → Seq(Groups) — visited groups this turn
    turn_blocked           \* keeper → BOOLEAN — BUG tracking

(* I5: Fallback count stays bounded. *)
FallbackCountBounded ==
    \A keeper \in Keepers : fallback_count[keeper] <= MaxFallbacks

ItemDegrade(keeper) ==
    /\ keeper_state[keeper] = "Turning"
    /\ ...
    /\ fallback_count[keeper] < MaxFallbacks   \* explicit precondition
    /\ ...
    /\ fallback_count' = [fallback_count EXCEPT ![keeper] = @ + 1]

GroupFallback(keeper) ==
    /\ ...
    /\ fallback_count[keeper] < MaxFallbacks   \* explicit precondition
    /\ ...
    /\ fallback_count' = [fallback_count EXCEPT ![keeper] = @ + 1]
```

`MaxFallbacks` is a CONSTANT — configurable per TLC run (cfg file).

PR #14668 (merged 2026-05-11) explicitly added the `<` precondition to
prevent TypeOK violation on overflow — confirms this is a recent
spec-side tightening.

## OCaml mechanism

`lib/keeper/keeper_cascade_selector.ml:5-72`:

```ocaml
let rec try_group group_name visited =
  if List.mem group_name visited then
    Error `No_available_item    (* cycle detection only *)
  else
    match find_group cascade_profile group_name with
    | None -> Error `No_available_item
    | Some group ->
        match find_healthy items with
        | Some item -> Ok (group_name, item)
        | None ->
            (match group.fallback_group with
             | Some next -> try_group next (group_name :: visited)
             | None -> Error `No_available_item)
```

The OCaml caps fallback *implicitly* via:
1. The `visited` list prevents revisiting a group.
2. Therefore the recursion depth is bounded by `O(profile.groups)` — the
   number of distinct groups in the cascade profile.

There is **no explicit `fallback_count` counter** and **no
`MaxFallbacks`-equivalent configuration**.

## Why the two mechanisms are not equivalent

Both terminate fallback, but they cap by different metrics:

| Mechanism | Cap source | Tunable? |
|---|---|---|
| TLA+ `fallback_count <= MaxFallbacks` | explicit counter | yes, via cfg CONSTANT |
| OCaml visited-list cycle detection | distinct-group count | no, derived from profile shape |

Consider a profile with 5 groups and `MaxFallbacks = 3`:

- **TLA+**: 3 fallbacks allowed before TypeOK violation.  4th attempt
  blocked by `fallback_count < MaxFallbacks` precondition.
- **OCaml**: 4 fallbacks allowed (visited would be `[g1, g2, g3, g4]`,
  pursuing `g5` is fine), 5th attempt blocked only when visited covers
  all groups.

This is a real semantic gap.  The spec `FallbackCountBounded` invariant
is enforced *in production* only because real cascade profiles
typically have fewer groups than the spec's `MaxFallbacks` setting.
Change either side independently — increase `MaxFallbacks` in cfg, or
add a 6th group to a profile — and the gap surfaces.

## Three concrete drift scenarios

1. **Spec re-verification with larger `MaxFallbacks`**:
   `MaxFallbacks = 10` in cfg, profile with 6 groups.  Spec admits 10
   fallbacks ⇒ TLC explores transitions OCaml can never execute.
   Spec coverage > production coverage; the spec catches no extra bugs.

2. **Profile expansion in production**:
   Operator extends a cascade profile to 8 groups while `MaxFallbacks`
   in cfg stays 5.  OCaml allows 8 fallbacks per turn, spec catches
   only 5.  Real OCaml behavior is *outside* the spec's reachable
   state space.

3. **Spec tightening for adaptive routing**:
   A future RFC introduces "early-exit" cap based on observed latency
   (e.g. abort fallback after 2 attempts if elapsed > budget).  This
   would correspond to a tighter `MaxFallbacks` in spec — but OCaml's
   visited-list cap can't model the budget-aware tightening.

## Suggested RFC fix paths

| ID | Scope | Action | Risk |
|---|---|---|---|
| R-C-1.a | OCaml-side parity | Add explicit `fallback_count` parameter to `try_group`, threading `~max_fallbacks` from a config source.  Pin the count alongside `visited` so cycle + counter both bound recursion. | MID — touches `select_item_for_turn` signature + caller (`keeper_cascade_routing.ml`?) + 1+ test files. |
| R-C-1.b | Spec-side relaxation | Drop `MaxFallbacks` from spec and rely on `NoGroupCycle` invariant alone.  TLC re-verify confirms cycle detection is sufficient.  Simpler spec; documents that the production mechanism is the SSOT. | LOW — spec change, TLC re-verify (5-15 min). |
| R-C-1.c | Both, with shared CONSTANT | Pin `MaxFallbacks` value identically in OCaml config and TLA+ cfg.  Add audit script to verify equivalence (R-B-1.c pattern). | MID — requires both implementations and a cross-check tool. |

R-C-1.b is the cheapest fix if the visited-list cycle detection is the
intended production semantics.  R-C-1.a preserves the spec's tighter
contract.  R-C-1.c bridges them at the cost of an extra invariant
check.

## Adjacent question — is `fallback_count` even tracked in production?

`grep -irn "fallback_count" lib/` returns matches only in:
- `lib/model_inference_metrics.ml` (LLM inference fallback metric — different domain)
- `lib/eval_calibration.ml`, `lib/dashboard/*` — telemetry/UI

None of these track the cascade-router-level fallback count the spec
models.  The mechanism mismatch isn't just about cap value — *the
counter itself is absent* on the OCaml side, only the *effect* of
bounded fallback is present (via cycle detection).

This deepens the spec coverage gap: the TLA+ `fallback_count` variable
is observable in spec traces (a Bug Model could assert "if
fallback_count[k] > N then some property holds"), but no equivalent
OCaml dashboard/log surface exposes the same count.

## Out-of-scope for this iteration

- TLC re-verification with R-C-1.b spec relaxation — separate PR.
- C-2 health asymmetric transitions audit — separate sub-aspect.
- C-3 fallback chain traversal vs OCaml `try_group` — overlaps with this
  audit, defer to a focused diff PR.

## References

- KCR spec line 33-42 (CONSTANTS), 55-65 (VARIABLES), 144-184 (ItemDegrade + GroupFallback), 259-260 (FallbackCountBounded invariant).
- OCaml `keeper_cascade_selector.ml:5-72` (`select_item_for_turn`).
- PR #14668: `fix(specs): cap fallback_count in ItemDegrade — KeeperCascadeRouting TypeOK clean fix` (merged 2026-05-11) — the spec-side tightening that exposed this OCaml gap.
- Adjacent pattern: KSM A-1 audit (`ksm-init-mapping-2026-05-12.md`) — same shape "OCaml ahead of spec on representation, spec stricter on contract".
- KTC B-1 audit (`ktc-b1-turn-phase-spec-gap-2026-05-12.md`) — sibling drift class.
