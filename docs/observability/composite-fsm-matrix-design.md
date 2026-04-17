# Composite FSM Matrix — Design

**Status**: Draft, iteration 1 (cron `cbf0ca92`, 20 min loop).
**Supersedes**: per-keeper FsmHub view (retained as drill-down).
**Formal basis**: `specs/keeper-state-machine/KeeperCompositeLifecycle.tla`.
**Prior art**: Harel 1987 (orthogonal regions), Bach et al. (small multiples > animation for discrete state change comprehension).

---

## 1. Problem

The keeper runtime exposes **6 orthogonal FSM axes** per entity and a **4-invariant joint specification** verifying their composition:

| Axis | Code site                           | States                                                                    | TLA+ spec                              |
| ---- | ----------------------------------- | ------------------------------------------------------------------------- | -------------------------------------- |
| KSM  | `keeper_state_machine.mli` (phase)  | Offline / Running / Failing / Overflowed / Compacting / HandingOff / Paused / Draining / Stopped / Crashed / Restarting / Dead | `KeeperStateMachine.tla`               |
| KTC  | `keeper_registry.mli:turn_phase`    | idle / prompting / executing / compacting / finalizing                    | `KeeperTurnCycle.tla`                  |
| KDP  | `keeper_registry.mli:decision_stage`| undecided / guard_ok / gate_rejected / tool_policy_selected               | `KeeperDecisionPipeline.tla`           |
| KCL  | `keeper_registry.mli:cascade_state` | idle / selecting / trying / done / exhausted                              | `KeeperCascadeLifecycle.tla`           |
| KMC  | `keeper_registry.mli:compaction_stage` | accumulating / compacting / done                                        | `KeeperCompactionLifecycle.tla`        |
| KCB  | `keeper_failure_circuit_breaker.ml` (counter-based) | clean / warning / cooling — `tripped` is unobservable because the mutator resets `consecutive_count` during the trip transition | `KeeperCircuitBreaker.tla`             |

The joint invariants (`phase_turn_alignment`, `no_cascade_before_measurement`, `compaction_atomicity`, `event_priority_monotone`) are already wired into `fsm-hub-types.ts:InvariantViolationCounts` and tracked in `HubState.invariantViolations`.

**Gap.** Both backend and dashboard are currently **per-keeper scoped**:

- Backend endpoint: `GET /api/v1/keepers/<name>/composite` — one keeper per call.
- Dashboard component: `FsmHub` in `agents-unified.ts:100` — renders the selected keeper only.

An operator who wants to *compare* keeper A's 6-axis state to keeper B's, or see which lanes across the fleet are stuck, has to page through keepers one at a time. The orthogonal structure is present in the data but **invisible at the fleet level**.

## 2. Design

### 2.1 Encoding

Four dimensions on a 2-D screen:

```
            ┌─ axis 1 ─┬─ axis 2 ─┬─ axis 3 ─┬─ axis 4 ─┬─ axis 5 ─┬─ axis 6 ─┐
keeper A    │ ▮▮▮▮▮▯▯  │ ▮▮▮▯▮▮▮  │ ▯▮▮▮▮▮▮  │ ▮▮▮▮▮▮▮  │ ▮▮▯▮▮▮▮  │ ▮▮▮▮▮▮▮  │
keeper B    │ ▯▮▮▮▮▮▮  │ ▯▯▯▮▮▮▮  │ ▮▮▮▯▯▮▮  │ ▮▮▮▮▯▯▯  │ ▮▮▮▮▮▮▮  │ ▯▮▮▮▮▮▮  │
keeper C    │ ▮▮▮▮▮▮▮  │ ▯▯▮▮▮▮▮  │ ▮▮▮▮▯▮▮  │ ▮▯▯▮▮▮▮  │ ▮▮▮▮▮▮▮  │ ▮▮▯▯▮▮▮  │
            └──────────┴──────────┴──────────┴──────────┴──────────┴──────────┘
row = keeper, col = FSM axis, cell = last N state chips (horizontal time axis).
```

- **Row**: keeper identity.
- **Column**: FSM axis (fixed order: KSM, KTC, KDP, KCL, KMC, KCB).
- **Cell**: N ≤ 30 horizontal chips, one per snapshot tick (oldest → newest left-to-right). Colour encodes state; non-transition ticks collapse to the same chip length so stalls become visibly wider blocks.
- **Time**: per-cell horizontal (same domain as the existing `MAX_OBSERVATIONS = 30`).

This gives row × col × time = 3 visible data dimensions + keeper-identity as a 4th via row ordering. It follows Harel's original rule: the product state space is **not** flattened — each axis renders as its own lane.

### 2.2 Why not 3-D / tesseract

Evaluated and rejected:

| Approach                      | Reason for rejection                                                            |
| ----------------------------- | ------------------------------------------------------------------------------- |
| Literal 3-D cube (three.js)   | Operators can't compare two cells at a glance under rotation; overkill for <100 cells. |
| Parallel coordinates          | Good for continuous axes; discrete states render as overlapping horizontal bands. |
| UpSet plot                    | Strong for static co-occurrence, weak for temporal trajectories.                |
| Cartesian product grid        | 12 × 5 × 4 × 5 × 3 = 3,600 cells; hits product-state explosion the spec is built to prevent. |

The chosen small-multiples matrix matches Bach et al. (2013) finding that small multiples beat animation for discrete state-change comprehension, and matches the XState inspector's approach to parallel regions (each region stays independent).

### 2.3 Invariant overlay

The 4 joint invariants are rendered as a **top strip** above the matrix:

```
[Phase ⇔ Turn: 0] [Cascade ordering: 2 ⚠] [Compaction atomicity: 0] [Event priority: 0]
```

When a count > 0, clicking it filters the matrix to show only keepers whose transitions contributed to that violation, and highlights offending cells in red. This is the one place the product state matters — it is where the joint spec is actually telling us something.

## 3. Surfaces to add

| Surface           | Path                                               | Status |
| ----------------- | -------------------------------------------------- | ------ |
| Backend endpoint  | `GET /api/v1/keepers/composite` (fleet, plural)    | new    |
| Backend observer  | `keeper_composite_observer.ml:all_snapshots`       | extend |
| API schema        | `dashboard/src/api/schemas/keeper-composite.ts`    | extend (`FleetCompositeSnapshotSchema`) |
| API client        | `dashboard/src/api/keeper.ts:fetchKeepersComposite`| new    |
| Component         | `dashboard/src/components/fleet-fsm-matrix.ts`     | new    |
| Component tests   | `dashboard/src/components/fleet-fsm-matrix.test.ts`| new    |
| Dashboard mount   | `agents-unified.ts`                                | extend (new sub-view or tab) |
| Prometheus counter| `masc_fleet_invariant_violations_total{invariant}` | new (LT-13) |
| Alerting rules    | `infrastructure/monitoring/cascade-alerts.yml`     | extend (LT-13) |
| Grafana panel     | `infrastructure/monitoring/grafana-cascade-dashboard.json` | extend (LT-13) |
| Spec cross-check  | `docs/observability/composite-fsm-matrix-design.md`| this file |

## 4. Spec ↔ code contract

Any state-label change is forbidden in exactly one place and required in every other. The full mandated-edit set:

1. OCaml variant (`keeper_state_machine.mli` or `keeper_registry.mli`).
2. TLA+ constants in `specs/keeper-state-machine/<Axis>.tla` plus the buggy `.cfg` pair.
3. `dashboard/src/api/schemas/keeper-composite.ts` `fallback()` union.
4. `fsm-hub-types.ts:displayState` mapping.
5. `fleet-fsm-matrix.ts` color map (new).
6. Grafana legend (new in LT-13).

`cascade-metrics.md` already documents this contract for the cascade axis; this doc extends it to all five.

## 5. Stage plan (cron-driven)

Each 20-minute tick lands at most one PR. Order minimises rebase contention.

| Tick | PR                                        | Changes                                                |
| ---- | ----------------------------------------- | ------------------------------------------------------ |
| T+1  | **LT-12** (this file)                     | Design doc only. 0 runtime change. Draft.              |
| T+2  | **LT-15** drift audit table               | `docs/observability/fsm-spec-code-drift.md`. 0 runtime change. |
| T+3  | **LT-13** invariant counts → Prometheus   | counter + alert + Grafana panel. Back-end + infra only.|
| T+4  | **LT-16a** backend fleet endpoint         | `keeper_composite_observer:all_snapshots` + route.     |
| T+5  | **LT-16b** frontend matrix component      | `fleet-fsm-matrix.ts` + tests + mount.                 |
| T+6  | **LT-14** OAS silent FSMs → event_bus     | cascade fallback, content_replacement, slot_scheduler. |

Each PR carries its own test suite. No PR merges without a TLA+ reference if it touches a state variant.

## 6. Risks

| Risk                                            | Mitigation                                                               |
| ----------------------------------------------- | ------------------------------------------------------------------------ |
| Fleet endpoint N+1: poll every keeper serially  | Observer fold at snapshot time; single JSON payload.                     |
| Dashboard render cost for 20 keepers × 6 axes × 30 chips | 3,600 DOM nodes — handled. CSS grid + state-chip memoization.      |
| Drift between spec and code                     | LT-15 produces drift table; any column with drift blocks its axis from matrix until resolved. |
| OAS silent FSMs leak through envelope causality | LT-14 publishes only; does not change state. OAS must not know MASC remains enforced. |
| Matrix overflows viewport at fleet > 50         | Row virtualisation + sort-by-violation-count. Defer until needed.        |

## 7. What this does not do

- No 3-D rotation. Tested visually and rejected.
- No custom layout engine (ELK, dagre). CSS grid is sufficient for a fixed 5-column layout.
- No FSM editor / interactive transitions. The dashboard is read-only.
- No cross-run trajectories. Time axis is within-session only (same constraint as existing `strategy_trace` ring).

## 8. References

- Harel, D. (1987). *Statecharts: A Visual Formalism for Complex Systems*. Sci. Comput. Programming.
- Bach, B., Pietriga, E., Fekete, J.-D. (2013). *GraphDiaries: Animated Transitions and Temporal Navigation for Dynamic Networks*. IEEE TVCG.
- Statecharts Online (ch. 5, orthogonal states). https://statecharts.online/chapters/05-orthogonal-states.html
- W3C SCXML §3.4 `<parallel>`.
- `specs/keeper-state-machine/KeeperCompositeLifecycle.tla` — source of truth for invariants.
- `docs/observability/cascade-metrics.md` — reference for the 5-surface consistency contract this doc extends.
