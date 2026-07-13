# External Comparison and Product Positioning

> OAS checklist #7 — MASC product positioning against comparable agent
> frameworks so that design decisions are anchored to explicit tradeoffs
> rather than implicit comparisons.

## Positioning axes

| Dimension | CLI-Tool-A / Provider-D Agent SDK / ADK | OpenClaw / Hermes / DAW | MASC |
|---|---|---|---|
| **Orchestration center** | Runner / session loop in the SDK | Workspace / memory graph | Operator-governed supervisor + runtime router |
| **Unit of execution** | Single agent turn (SDK dispatches) | Tool composition graph | Keeper turn with pre-dispatch gates, provider attempts, and receipt proofs |
| **State ownership** | Client process holds session state | Shared workspace / memory bank | Keeper registry + execution receipts + runtime manifest |
| **Failure model** | SDK exception / retry config | Graph node retry | Typed FSM terminal states with receipt append-before-return |
| **Observability** | SDK event stream | Memory change log | Multi-layer: receipt → manifest → runtime-trace → dashboard lens → SSE |
| **Human operator** | Debugging via client logs | UI over workspace | First-class: operator controls runtime, policy, phase, and can inspect every gate decision |

## Design implications

### What MASC does not optimize for

- **Single-turn latency**: MASC adds pre-dispatch gates (phase, livelock, runtime build) that a direct SDK runner skips. The tradeoff is determinism over speed.
- **Agent autonomy**: Keepers run supervised cycles, not self-driven loops. The tradeoff is operator visibility over agent initiative.
- **Minimal setup**: MASC requires runtime.toml, keeper personas, and a running agent stream. The tradeoff is durable multi-Keeper coordination and an explicit external-effect Gate over single-user convenience.

### What MASC optimizes for

- **Fleet-level reproducibility**: Every keeper turn produces a receipt with a typed outcome before any side effect reaches the operator dashboard. This makes "what happened and why" traceable across restarts.
- **Provider-agnostic routing**: The runtime router resolves tool requirements into provider attempts without hardcoding provider URLs or model IDs in agent logic.
- **Graduated trust**: Phase gates (idle, heartbeat, direct, autonomous) let operators increase keeper autonomy as confidence grows, rather than choosing between fully manual and fully automatic.

## Comparison pitfalls to avoid

| Anti-pattern | Why it misleads | Correct framing |
|---|---|---|
| "MASC is slower than CLI-Tool-A" | Ignores pre-dispatch determinism | MASC turns are receipt-guaranteed; SDK turns are fire-and-forget unless the client adds bookkeeping |
| "MASC is like AutoGPT" | AutoGPT is goal-driven loop; MASC is operator-governed phase machine | Keeper autonomy is bounded by phase policy and runtime materialization, not by goal decomposition |
| "MASC replaces the Provider-D SDK" | MASC sits at a different layer | MASC dispatch emits SDK calls (Provider-D, Provider-A, Provider-K, Ollama) as provider attempts; it is a router, not a client replacement |

## When to use what

| Situation | Use CLI-Tool-A / ADK | Use MASC |
|---|---|---|
| One-shot script, single provider, developer machine | Direct SDK call is sufficient | Overhead exceeds value |
| Multi-step workflow with tool failure retry | SDK runner with retry config | Keeper turn FSM handles retry as runtime rotation with receipt proof |
| Fleet of agents with different policies | Manage N SDK clients externally | Single agent stream with per-keeper phase and runtime rules |
| Operator must approve or audit every action | Not supported natively | Phase gate blocks autonomous turns until operator releases |
| Cross-provider failover (Provider-D down → Provider-K) | Manual fallback code | Runtime router materializes alternatives automatically |

## References

- `docs/keeper-turn-lifecycle.md` — turn-level execution model
- `lib/keeper/keeper_turn_fsm.mli` — typed FSM states
- `lib/keeper/keeper_runtime_engine.mli` — runtime routing boundary
- OAS analysis 2026-05-21 §8 — external comparison checklist origin
