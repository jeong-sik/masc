# KeeperCoreTriad S2/S3 Audit — Failing & Buffer Cascade Alignment

**Iteration**: 26 (/loop FSM/TLA+/OCaml drift hunt)
**Date**: 2026-05-12
**Spec**: `specs/keeper-state-machine/KeeperCoreTriad.tla` §S2 FailingUsesRecovery, §S3 BufferOpsUseLocalOnly
**OCaml**: `lib/keeper/keeper_cascade_routing.ml:20-25`, `lib/keeper/keeper_config.ml:26-33`, `lib/cascade/cascade_routes.ml:64-65, 209-271`
**Risk**: LOW — alignment is correct in the *default* deployment.  Configuration-dependent gap: operator-supplied catalogs/routes may resolve to non-spec names, in which case spec-literal match no longer holds verbatim — though the *intent* (use recovery / buffer profile, not main keeper cascade) is preserved.
**Type**: Audit-only (no code change in this PR).  Companion to C-3 (terminal cascade) audit.

## TLA+ S2/S3 contracts

```tla
(* Spec line ~365: *)
FailingUsesRecovery ==
    (phase = "Failing" /\ turn_status = "selecting" /\ effective_cascade /= "none")
        => effective_cascade = "local_recovery"

(* Spec line ~370: *)
BufferOpsUseLocalOnly ==
    (phase \in {"Compacting", "HandingOff"}
     /\ turn_status = "selecting"
     /\ effective_cascade /= "none")
        => effective_cascade = "local_only"
```

Both are **conditional implication** invariants gated on `turn_status = "selecting"`
(an upstream caller responsibility).  `select_cascade` itself is
phase-only — it does not know `turn_status`.

## OCaml dispatch (the *intent* side)

```ocaml
(* lib/keeper/keeper_cascade_routing.ml:20-25 *)
| Failing ->
    { effective_cascade = Keeper_config.local_recovery_cascade_name;
      reason = "failing phase: cheap local recovery" }
| Compacting | HandingOff ->
    { effective_cascade = Keeper_config.local_only_cascade_name;
      reason = "buffer operation: local model sufficient" }
```

Intent matches the spec: Failing → recovery profile, Compacting|HandingOff →
buffer profile.  Provenance of the *string value* is the issue.

## String value resolution (the *literal* side)

```ocaml
(* lib/keeper/keeper_config.ml:26-33 *)
let local_recovery_cascade_name =
  Keeper_cascade_profile.cascade_name_for_use Phase_recovery

let local_only_cascade_name =
  Keeper_cascade_profile.cascade_name_for_use Phase_buffer
```

```ocaml
(* lib/cascade/cascade_routes.ml:64-65 — route spec *)
| Phase_recovery -> route Phase_recovery "phase_recovery" [ "local_recovery" ]
| Phase_buffer   -> route Phase_buffer   "phase_buffer"   [ "local_only" ]

(* lib/cascade/cascade_routes.ml:251-271 — resolution *)
let cascade_name_for_use ?config_path use =
  let route_target = configured_route_bindings ... in
  let catalog_names = ... in
  let fallback = fallback_from_entries use entries in
  match route_target with
  | Some target when catalog_names = [] -> fallback     (* uses first alias *)
  | Some target when List.mem target catalog_names -> target
  | Some target -> fallback                              (* invalid target *)
  | None -> fallback
```

`fallback_from_entries`:
1. If `entries` (catalog) is non-empty → returns *first catalog entry's
   `name`*, ignoring the aliases.
2. Else → `first_alias_or_key spec` — for `Phase_recovery` this is
   `"local_recovery"`, exactly the spec literal.

## Three resolution scenarios

| Scenario | Catalog state | Operator route | Resolved name | Spec match? |
|---|---|---|---|---|
| **Default boot** (empty catalog) | `[]` | None | first alias: `"local_recovery"` / `"local_only"` | ✅ exact |
| **Catalog without route override** | non-empty, has profile named e.g. `"recovery"` | None | *first catalog entry name* | ❌ probably not literal |
| **Operator route to a catalog profile** | non-empty | `"phase_recovery": "custom_recovery"` if in catalog | `"custom_recovery"` | ❌ |

The spec assumes scenario 1's literal value, but production frequently
runs scenarios 2/3.

## Why this isn't a runtime bug today

- The spec's `effective_cascade` is an abstract *cascade identity*, not a
  string-equality assertion in production code.  No OCaml branch reads the
  output of `select_cascade` and asserts `= "local_recovery"`.
- The intent (use a recovery/buffer profile, not the main keeper cascade)
  *is* preserved through the `Phase_recovery` / `Phase_buffer` typed
  enum — the indirection is in *which catalog name implements that role*.
- The `turn_status = "selecting"` gate in S2/S3 is a callsite invariant,
  not a property of `select_cascade`.  Upstream
  (`keeper_unified_turn.ml:411` per C-3 audit) gates the call appropriately.

So S2/S3 hold *in production* via the typed `logical_use` indirection,
not via literal string equality.

## Why the spec is brittle here

The spec encodes a string literal as the contract surface:

```tla
effective_cascade = "local_recovery"   \* hard-coded string
```

This is the same anti-pattern as KCT terminal cascade (C-3) — spec
overspecifies a value that production legitimately abstracts.  The spec
captures *intent* with the string, but the *identifier* is a moving target
on the production side.

## Three RFC candidates

| ID | Direction | Risk |
|---|---|---|
| R-S2.a | **Spec — relax to symbolic identifiers**. Introduce spec CONSTANTs `RECOVERY_PROFILE`, `BUFFER_PROFILE` instead of hardcoded strings.  Spec retains intent, decouples from production string churn.  Matches the typed `logical_use` design. | LOW (spec change, TLC re-verify) |
| R-S2.b | **OCaml — sentinel constants on the *spec* side**. Force `local_recovery_cascade_name` to a build-time literal `"local_recovery"` (no catalog lookup), and treat operator routing as a *separate* layer mapping that name to catalog profiles. | MID (boots into stronger invariants but loses operator flexibility on naming) |
| R-S2.c | **Both — document the abstraction**. Add a spec comment §S2 explaining `"local_recovery"` is the canonical name of the role, not the operator's catalog entry name; cross-reference `Keeper_cascade_profile.Phase_recovery`.  No code change. | LOW (doc only) |

R-S2.c is the cheapest — admits the typed-identifier abstraction is the
SSOT and the spec literal is a stand-in.  R-S2.a is the structurally
cleaner fix (CONSTANT → cfg parameter).  R-S2.b is a regression of
operator-driven naming flexibility and is **not recommended**.

## Comparison with C-3 (terminal cascade gap)

C-3 (kct-c3-terminal-cascade-contract-gap-2026-05-12.md) noted that
`select_cascade` returns `base_cascade` for terminal phases where spec
requires `"none"`.  The gap is similar in *shape* (spec wants a specific
string; OCaml emits a different one) but **opposite in direction**:

| Audit | Spec wants | OCaml emits | Gap shape |
|---|---|---|---|
| C-3 (Terminal) | `"none"` | `base_cascade` | OCaml *more permissive* than spec |
| S2/S3 (this) | `"local_recovery"` / `"local_only"` | catalog-resolved name | OCaml *more configurable* than spec |

Both are **paper contract gaps**, neither is a runtime bug, both surface
when an extra layer (callsite gating, operator config) is taken into
account.

## Recommended next step

R-S2.c (doc-only spec comment) is the cheapest path to align spec
expectations with production reality.  It can be bundled with R-C-3.c
(terminal cascade spec relaxation) into a single small spec doc PR that
acknowledges the typed-identifier abstraction as the SSOT.

## Out-of-scope for this iteration

- S3 second component (CapabilityGateHolds): `turn_status = "executing"`
  predicate on `requested_max_tokens` — different mechanism (token budget
  not cascade selection), separate audit.
- S4 SideEffectContainment, S5 PhaseDecisionConsistency — different
  invariant families, separate audits.
- R-C-3.b sentinel implementation — risky (test impact), deferred.

## References

- KCT spec §S2 (FailingUsesRecovery), §S3 (BufferOpsUseLocalOnly,
  CapabilityGateHolds).
- `lib/keeper/keeper_cascade_routing.ml:20-25` (intent dispatch).
- `lib/keeper/keeper_config.ml:26-33` (name resolution call).
- `lib/cascade/cascade_routes.ml:64-65, 209-271` (route_spec + fallback
  resolution).
- C-3 audit (`kct-c3-terminal-cascade-contract-gap-2026-05-12.md`) —
  sibling spec-literal gap pattern.
- RFC-0058 (declarative route mapping) — origin of the indirection layer.
