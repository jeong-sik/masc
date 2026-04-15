# Keeper Social Model Inventory

Status: active implementations + research inventory

See also:

- `docs/design/keeper-social-model-fsm.md`

## Active implementations

### `bdi_speech_v1`

- Role: current keeper social model
- Implementation status: active production baseline
- Fit: best fit for the existing keeper + board + task + status architecture
- Core idea:
  - the model explicitly emits a typed social-state header
  - code validates and routes that act
  - board/task/broadcast remain the only outward surfaces
- Why active now:
  - keeper already has `will / needs / desires`
  - unified turn already records trigger/affordance/outcome artifacts
  - this adds explicit expression without replacing the current harness

## Inventory candidates

### `magentic_ledger_v1`

- Role: progress/stall-oriented planning overlay
- Implementation status: implemented secondary registry target
- Best use: detect stuck work, stalled loops, replanning triggers
- Why not default now:
  - good for task/progress ledgers
  - weaker as the primary social-expression model
- Implementation note:
  - tool evidence is treated as progress-ledger state, so tool-only turns can
    stay silent instead of synthesizing an extra visible reply
  - the implementation now uses a pure phase/event FSM plus a matching TLA+
    spec for the closed state set

Reference:
- Magentic-One article
- https://www.microsoft.com/en-us/research/articles/magentic-one-a-generalist-multi-agent-system-for-solving-complex-tasks/

### `reaction_identity_v2`

- Role: history/emergence-driven keeper identity
- Implementation status: documented candidate only
- Best use: diversity, long-horizon persona drift, reaction-history experiments
- Why not default now:
  - useful research track
  - too indirect for immediate blocker/request-help expression

Related local context:
- `docs/archive/keeper-autonomy-identity-v2/ARCHITECTURE.md`
- `docs/archive/keeper-autonomy-identity-v2/RESEARCH.md`

### `tom_diversity_v1`

- Role: cross-agent expectation modeling
- Implementation status: documented candidate only
- Best use: diversity maintenance, consensus-vs-dissent control
- Why not default now:
  - high complexity
  - requires more state and scaling work than current keeper loop needs

Reference:
- Jason / BDI ecosystem for explicit agent mental state
- https://jason-lang.github.io/jason/

### `hitl_intervention_v1`

- Role: approval/handoff/escalation overlay
- Implementation status: documented candidate only
- Best use: operator gating, action previews, external approval
- Why not default now:
  - complements social routing
  - does not replace it

References:
- LangGraph HITL docs
- https://docs.langchain.com/oss/javascript/deepagents/human-in-the-loop
- AutoGen intervention + handoff docs
- https://microsoft.github.io/autogen/dev/user-guide/core-user-guide/cookbook/tool-use-with-intervention.html
- https://microsoft.github.io/autogen/dev/user-guide/core-user-guide/design-patterns/handoffs.html

## Selection rule

Until `social_model` becomes a richer user-facing axis:

- runtime default stays `bdi_speech_v1`
- `social_model` should not be presented as a rich user-facing strategy selector yet
- unknown runtime values should fail fast or fall back explicitly to `bdi_speech_v1`
