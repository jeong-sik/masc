---
status: reference
last_verified: 2026-07-13
code_refs:
  - lib/keeper/keeper_keepalive.ml
  - lib/keeper/keeper_heartbeat_loop.ml
  - lib/keeper/keeper_unified_turn.ml
  - lib/keeper/keeper_agent_run.ml
  - lib/keeper/keeper_keepalive_signal.ml
  - lib/keeper/keeper_execution_receipt.ml
  - specs/keeper-state-machine/KeeperHitlDeferred.tla
---

# Turn Lifecycle

> Part of: [SPEC-INDEX](./SPEC-INDEX.md)

## 1. One timeline per Keeper

Each Keeper owns one durable FIFO lane. Board mentions, Task changes,
Channel and Connector messages, Scheduler events, Job completions, Gate
resolutions, Fusion results, and operator messages enter that lane as typed
stimuli with correlation and source-space identity.

A busy Keeper does not lose new input. The stimulus remains queued. Where a
connector supports an immediate reply, the Keeper may acknowledge that it is
busy while preserving the original stimulus for a later turn.

No Keeper failure or pending request blocks another Keeper lane.

## 2. Cycle

```text
wait for typed stimulus
  -> consume next durable lane item
  -> build source observations
  -> configured LLM decides the next action
  -> execute OAS turn and registered tools
  -> persist transcript, tool results, and receipt
  -> enqueue follow-up stimuli/jobs
  -> wait for the next item
```

FIFO defines delivery order. The configured LLM decides semantic relevance,
whether to reply, defer, continue existing work, or start another action. A
string classifier, score, timeout strike, progress count, or hardcoded product
name cannot make that decision.

## 3. OAS boundary

MASC supplies OAS with the selected runtime, conversation, multimodal parts,
and the registered tool surface. OAS owns provider/model calls, streaming,
reasoning/tool protocol support, and typed provider outcomes. OAS remains
generic and imports no Keeper, Task, Board, Connector, or Gate module.

Provider/model errors return as typed observations. They may cause the Keeper
to choose a fallback runtime on a later action, but they do not increment a
policy strike, create a cooldown, pause the Keeper, or stop its lane.

## 4. Tool dispatch and Gate

Registered tool descriptors and typed schemas are the tool-surface SSOT. Tool
names, command strings, repositories, vendors, and credential kinds are not
reclassified inside Keeper lifecycle code.

Objective invariants stay at their natural boundary: typed arguments,
`BasePath` containment, sandbox isolation, atomic version checks, and explicit
resource errors.

When an outer product configuration requires a decision, dispatch uses the
generic Gate mode:

- `Always_allow`: dispatch immediately after objective invariants pass;
- `Auto_judge`: the configured LLM returns approve/deny/require-human with
  rationale and provenance;
- `Manual`: persist a nonblocking HITL request and return `Deferred`.

There is no separate effect-request domain object, fixed risk class,
privileged floor, product-specific exemption, or hidden authorization
hierarchy. A Gate request references the original registered operation and
carries an exact outer-turn causal-context snapshot. The Gate stores and
forwards that snapshot opaquely without learning a vendor or tool.

Gate resolution is consumed exactly once and wakes only the originating lane.
The Keeper remains free to perform unrelated work while a request is pending.

## 5. Long-running work

Long-running Tool, Connector, Scheduler, and Fusion activity becomes a Job.
Submitting a Job returns its durable handle. Completion or failure appends a
typed stimulus to the origin lane. Polling is allowed when the external system
has no callback, but polling state is Job-local and never holds the Keeper
fiber or a fleet-wide slot.

## 6. Transcript and observability

Each turn records, in order:

- source stimulus and correlation;
- selected runtime/model and fallback provenance;
- assistant reasoning/thinking parts allowed by the provider contract;
- tool calls, tool results, images/audio/text parts, and interleaving order;
- Gate and Job references;
- terminal OAS outcome or cancellation;
- token, latency, and throughput measurements.

Missing or malformed evidence is an explicit error. A receipt is evidence of
what happened, not authority to pause, retry, or stop the Keeper.

## 7. Lifecycle authority

Only explicit operator stop and durable process-death tombstone end a Keeper
lane. Ordinary provider failure, context compaction, a pending Gate, an unmet
Task, FD/disk pressure, no tool call, or lack of recent activity cannot do
so. Compaction and handoff are lane-local maintenance and must wake or continue
the lane when complete.

## 8. Required invariants

- `INV-TURN-001`: every stimulus is durably queued or returns a typed error.
- `INV-TURN-002`: at most one turn mutates one Keeper timeline at a time.
- `INV-TURN-003`: unrelated Keeper lanes always remain progress-capable.
- `INV-TURN-004`: HITL submission is nonblocking and origin-local.
- `INV-TURN-005`: every tool/provider outcome is explicit and observable.
- `INV-TURN-006`: semantic decisions are configured LLM judgments, not local
  heuristics.
- `INV-TURN-007`: only explicit stop/death owns terminal lifecycle authority.
