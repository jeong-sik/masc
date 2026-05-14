# KCR Phase C-2 Audit — Health State Representation Gap

**Iteration**: 23 (/loop FSM/TLA+/OCaml drift hunt)
**Date**: 2026-05-12
**Spec**: `specs/keeper-state-machine/KeeperCascadeRouting.tla` §57 (item_health), §189-193 (ItemRecover), §144-167 (ItemDegrade)
**OCaml**:
  - `lib/keeper/keeper_health_probe.ml:9-12` (`type health_status`)
  - `lib/cascade/cascade_health_tracker.ml:297, 509, 524-555` (`consecutive_failures` mutation)
**Risk**: MID — spec and OCaml encode the same asymmetric "multi-hop fail / one-shot recover" semantics, but with *different state representations*.  Spec invariants are well-formed but cannot speak about the OCaml temporal cooldown dimension.
**Type**: Audit-only (no code change in this PR).

## Spec health model

```tla
\* Per-item-per-keeper typed health: closed 3-state set.
item_health \in [Keepers × Items → {"Healthy", "Degraded", "Unhealthy"}]

\* Spec invariant pinning health to consecutive_failures:
HealthStateConsistent ==
    \A k \in Keepers, i \in Items :
        LET h = item_health[<<k, i>>]
            cf = consecutive_failures[<<k, i>>]
        IN /\ (h = "Healthy"   => cf = 0)
           /\ (h = "Degraded"  => cf > 0 /\ cf < MaxConsecutive)
           /\ (h = "Unhealthy" => cf >= MaxConsecutive)

\* Multi-hop failure path (Healthy → Degraded → Unhealthy):
ItemDegrade(keeper) ==
    /\ ...
    /\ LET cf = consecutive_failures[k_item] + 1
           new_health = IF cf >= MaxConsecutive THEN "Unhealthy" ELSE "Degraded"
       IN /\ item_health' = [item_health EXCEPT ![k_item] = new_health]
          /\ consecutive_failures' = [consecutive_failures EXCEPT ![k_item] = cf]

\* One-shot recovery (Degraded/Unhealthy → Healthy):
ItemRecover(keeper, item) ==
    /\ item_health[<<keeper, item>>] \in {"Degraded", "Unhealthy"}
    /\ item_health' = [item_health EXCEPT ![<<keeper, item>>] = "Healthy"]
    /\ consecutive_failures' = [consecutive_failures EXCEPT ![<<keeper, item>>] = 0]
```

## OCaml health model

### Typed surface — `Keeper_health_probe.health_status`

```ocaml
type health_status =
  | Healthy
  | Unhealthy of string  (* reason *)
```

**Only 2 states, no Degraded variant.**  Module comment at line 41-42:
> "Success -> Healthy immediately. Failure -> Unhealthy (no Degraded intermediate for now)."

### Implicit intermediate — `cascade_health_tracker.consecutive_failures`

```ocaml
(* lib/cascade/cascade_health_tracker.ml:297 *)
mutable consecutive_failures: int;

(* Success: reset *)
| Success ->
  state.consecutive_failures <- 0;
  state.cooldown_until <- 0.0;        (* clear time-based gate *)

(* Failure | Rejected: increment, threshold-gate cooldown *)
| Failure | Rejected ->
  state.consecutive_failures <- state.consecutive_failures + 1;
  ...
  if state.consecutive_failures >= threshold then
    state.cooldown_until <- now +. cooldown_dur

(* Soft_rate_limited: immediate short cooldown, no failure count gate *)
| Soft_rate_limited ->
  state.cooldown_until <- now +. soft_cooldown
```

OCaml's "Degraded" equivalent is implicit:
`0 < consecutive_failures < threshold`.  No typed variant captures it —
the predicate is computed from the count.

## Side-by-side mapping

| TLA+ typed state | OCaml predicate |
|---|---|
| `Healthy` | `consecutive_failures = 0 ∧ cooldown_until ≤ now` |
| `Degraded` | `0 < consecutive_failures < threshold ∧ cooldown_until ≤ now` |
| `Unhealthy` | `consecutive_failures ≥ threshold ∨ cooldown_until > now` |
| *(no spec equivalent)* | `Soft_rate_limited` outcome triggers cooldown without failure-count gate |

## Symmetry: failure multi-hop, recovery one-shot

| Direction | Spec | OCaml |
|---|---|---|
| Healthy → Degraded → Unhealthy | `ItemDegrade` (cf++, state transitions on threshold cross) | `consecutive_failures++` (state implicit) |
| Degraded → Healthy | `ItemRecover` (one-shot reset) | `Success` (cf=0, cooldown cleared) |
| Unhealthy → Healthy | `ItemRecover` (one-shot reset) | `Success` (cf=0, cooldown cleared) |
| Unhealthy → Degraded | **not modeled** | **not modeled** — only Healthy as recovery target |

Both sides agree on the asymmetric shape: failure climbs through
states; recovery collapses straight to Healthy.  This is *intentional*
in production (a fresh success means the provider is back) and matches
the spec.

## Where the gap surfaces (4 cases)

### 1. Soft_rate_limited has no spec counterpart

`Soft_rate_limited` short-circuits to cooldown without incrementing
`consecutive_failures`.  Spec's `ItemDegrade` requires
`fallback_count[keeper] < MaxFallbacks` and increments `cf`; spec has
no separate "transient throttle" action.  A run where OCaml fires
Soft_rate_limited 10× would be invisible to spec — `cf` stays at 0,
`item_health` stays at `Healthy`, but production keeper is gated by
cooldown.

### 2. Cooldown decouples Unhealthy from `cf`

Spec: `cf ≥ MaxConsecutive` ⇔ `Unhealthy`.
OCaml: `cf ≥ threshold OR cooldown_until > now`.

After `cooldown_dur` elapses without a failure, `cooldown_until ≤ now`
again, so OCaml is effectively Degraded (cf unchanged at threshold).
Spec has no notion of *time-elapsed re-Degradation* — once Unhealthy,
the spec must transition through `ItemRecover` to leave the state.

### 3. Per-item-per-keeper vs per-provider-key granularity

Spec key: `<<keeper, item>>` — health is per (keeper, item) pair.
OCaml `cascade_health_tracker` keys: `provider_key` (a single string,
shared across keepers per cooldown_config — see `cooldown_config_for
~provider_key`).  This means in OCaml two keepers using the same
provider share the cooldown state; in spec they don't.

This is a **structural-level mismatch**, not a counter mismatch.
TLA+ `PerKeeperIsolation` invariant is declared `== TRUE` with the
comment *"Structural invariant: enforced by variable typing"* — the
spec asserts isolation that production *does not* uphold for the
cooldown axis.

### 4. The 2-state OCaml `health_status` is unused for cascade health

`Keeper_health_probe.health_status` (Healthy/Unhealthy) is the *probe*
type — it summarizes cascade ratio observability, not the cascade
selector's per-item decision.  The selector
(`keeper_cascade_selector.try_group`) calls
`Keeper_health_probe.is_item_healthy ~keeper_name ~item_id` which
returns a `bool` derived from a different cache.  The spec's 3-state
typing doesn't live in OCaml at all — it's distributed across the
`consecutive_failures` int, the `cooldown_until` float, and the
boolean predicate.

## Three RFC candidates

| ID | Direction | Risk |
|---|---|---|
| R-C-2.a | OCaml typed surface — add `Degraded of { failures: int }` variant to expose the implicit state.  Pure types refactor — derives from `consecutive_failures` count via smart constructor.  Dashboards / `is_item_healthy` benefit. | MID (signature change) |
| R-C-2.b | Spec extension — add `SoftRateLimit(keeper, item)` action that transitions `item_health` to `Unhealthy` via cooldown semantics, separate from `cf` threshold.  Requires a `cooldown_until` variable.  Then drop `PerKeeperIsolation == TRUE` placeholder. | MID (spec change + TLC re-verify) |
| R-C-2.c | Drop `PerKeeperIsolation` placeholder — replace with a documented operational invariant that the *cascade tracker keys by provider, not keeper*.  Spec less precise, but honest. | LOW (spec doc change only) |

R-C-2.c is the cheapest *correction* — removes a spec lie.
R-C-2.a is the highest-leverage *production* fix — makes
state-implicit thinking explicit, paving the way for snapshot invariant
checking (the R-A-6.c pattern applied to cascade health).

## Out-of-scope for this iteration

- R-B-1.c annotation drift check on `Keeper_health_probe.health_status`
  — its 2 variants are inferentially aligned with spec's 3 states (with
  `Degraded` collapsing to `Healthy` since OCaml has no Degraded
  variant), so the validator can't catch this gap.  This is a
  *different* drift class.
- C-3 fallback chain traversal — separate sub-aspect.
- `Soft_rate_limited` semantics formalization — RFC scope.

## References

- KCR spec §57, §189-193, §144-167, §250-256
- `lib/keeper/keeper_health_probe.ml:9-12` (typed 2-state)
- `lib/cascade/cascade_health_tracker.ml:297, 500-580` (implicit intermediate + cooldown)
- KSM A-1 audit (`ksm-init-mapping-2026-05-12.md`) — same shape "OCaml different representation, spec stricter typing"
- KCR C-1 audit (`kcr-c1-fallback-cap-mechanism-gap-2026-05-12.md`) — sibling drift class (counter mechanism mismatch)
- PR #14668 (spec tightening that exposed C-1)
