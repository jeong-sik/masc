# KeeperCoreTriad C-3 Audit — Terminal Cascade Contract Gap

**Iteration**: 25 (/loop FSM/TLA+/OCaml drift hunt)
**Date**: 2026-05-12
**Spec**: `specs/keeper-state-machine/KeeperCoreTriad.tla` §S1 NoTerminalCascade (line 361-363)
**OCaml**: `lib/keeper/keeper_cascade_routing.ml:32-34` (`select_cascade` for terminal phases)
**Risk**: LOW — silent contract gap, currently *not exercised* because terminal keepers don't drive turn dispatch.  Would surface if a code path invoked `select_cascade` on a phase that the spec considers terminal but doesn't gate the call site.
**Type**: Audit-only (no code change in this PR).

## File-naming clarification (plan correction)

The plan's Phase C-3 sub-aspect is described as "Fallback chain traversal
↔ `keeper_cascade_routing.ml`".  Reading the file reveals:
**`keeper_cascade_routing.ml` does NOT implement fallback chain
traversal** — that lives in `keeper_cascade_selector.ml:try_group`
(already audited in C-1 #14776).  `keeper_cascade_routing.ml`
implements *phase-aware cascade selection* and mirrors
`KeeperCoreTriad.tla`'s `SelectCascade` action, not
`KeeperCascadeRouting.tla`'s `ItemDegrade` / `GroupFallback`.

So the true content of "C-3" is a different audit: how
`select_cascade` honors `KeeperCoreTriad.SafetyInvariant` (S1-S5).
This memo covers S1 (NoTerminalCascade) — the others are independent
follow-ups.

## TLA+ S1 contract

```tla
(* Spec phase set, line 106: *)
Phases == {"Running", "Failing", "Overflowed", "Compacting",
           "HandingOff", "Draining", "Terminal"}

(* Spec mapping comment, line 102: *)
\*   "Terminal"    ↔ Offline | Paused | Stopped | Crashed | Restarting | Dead

(* S1 invariant, line 361-363: *)
NoTerminalCascade ==
    phase = "Terminal" => effective_cascade = "none"
```

The spec collapses 6 KSM phases into a single abstract `"Terminal"`
and requires that the effective cascade for those phases is `"none"`.

## OCaml behavior

```ocaml
(* lib/keeper/keeper_cascade_routing.ml:32-34 *)
| Offline | Stopped | Dead | Zombie | Crashed | Restarting ->
    { effective_cascade = base_cascade;
      reason = "non-turn phase (blocked upstream)" }
```

For *all six* KSM phases the spec calls "Terminal", OCaml returns
`base_cascade` — a real cascade name, not `"none"`.  The reason
string admits this is a non-turn phase ("blocked upstream") but the
*return value* still carries the base cascade.

Note: `Paused` is also in the spec's "Terminal" abstraction but in
OCaml's switch it falls under `Draining | Paused -> base_cascade`
(line 29-31) with a *different* reason ("winding down: complete
in-progress work").  Same end value, different intent.  `Zombie` is
extra — present in OCaml but not mentioned in spec line 102's
mapping comment.

## Why this is technically a contract violation

`KeeperCoreTriad.SafetyInvariant` lists `NoTerminalCascade` as a
required property.  If OCaml passed the result of
`select_cascade phase=Stopped` to any production code that asserts
S1 (e.g. "if phase = Terminal then effective_cascade must = none"),
the assertion would fail.

## Why production stays correct (today)

The two production callers don't exercise this contract violation:

1. `lib/keeper/keeper_unified_turn.ml:411` — invoked from the turn
   execution path.  Turn execution is upstream-gated by the keeper
   FSM: a Dead/Stopped/Zombie keeper doesn't enter turn cycle at all.
   So `select_cascade` is effectively only called for Running/Failing/
   buffer-op phases.
2. `lib/server/server_dashboard_http_keeper_api.ml:1423` — dashboard
   render path.  Read-only; no S1 assertion downstream.

The `base_cascade` return for terminal phases is *unreachable in
production*, making this a paper contract gap rather than a runtime
bug.

## Three RFC candidates

| ID | Direction | Risk |
|---|---|---|
| R-C-3.a | OCaml — return `Result.t` (or option) from `select_cascade`, with `Error/None` for terminal phases.  Forces callers to handle the case explicitly.  Honors S1 at the type level. | MID (signature change) |
| R-C-3.b | OCaml — return an "effective_cascade = `none`" sentinel string for terminal phases.  Caller responsibility unchanged but value matches spec.  Less type-safe than R-C-3.a but minimal disruption. | LOW (single-file change) |
| R-C-3.c | Spec — relax `NoTerminalCascade` to acknowledge that callers are gated upstream; document that the spec's `"none"` is an abstraction over "OCaml caller never asks for terminal-phase cascade".  Add the gating predicate as a separate invariant on the *call graph*, not the function return. | LOW (spec docs only) |

R-C-3.b is the cheapest production-side honoring of S1 (a single arm
edit + update comment).  R-C-3.a is structurally cleaner but
cascades through 2 callers + tests.  R-C-3.c documents reality.

## Adjacent observation — `Zombie` not in spec mapping

Spec line 102's terminal-mapping comment lists *6 KSM phases* but
omits `Zombie`.  OCaml `Zombie` falls through to `base_cascade`
with the "non-turn phase" reason.  The omission may be a doc lag
(spec written before Zombie was added) or a deliberate signal that
Zombie has different semantics than Stopped/Dead.  Worth verifying
on next KCT audit pass.

## Out-of-scope for this iteration

- S2-S5 cross-checks (FailingUsesRecovery, BufferOpsUseLocalOnly,
  CapabilityGateHolds, SideEffectContainment, PhaseDecisionConsistency).
  Each is a separate audit slice and deserves its own focused PR.
- Plan-level fix: the project plan's C-3 description references the
  wrong file.  Update at plan-revision time.

## References

- KCT spec §361-363 (NoTerminalCascade), §102 (phase mapping), §106 (Phases set).
- `lib/keeper/keeper_cascade_routing.ml:32-34`.
- Callers: `lib/keeper/keeper_unified_turn.ml:411`,
  `lib/server/server_dashboard_http_keeper_api.ml:1423`.
- C-1 audit (`kcr-c1-fallback-cap-mechanism-gap-2026-05-12.md`) — different domain (KCR.tla, not KCT.tla).
- KSM A-1 (`ksm-init-mapping-2026-05-12.md`) — same shape "spec contract vs OCaml return value".
