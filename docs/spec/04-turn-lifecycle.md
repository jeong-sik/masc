---
status: reference
---

# Turn Lifecycle

> Part of: [SPEC-INDEX](./SPEC-INDEX.md)

## 1. One timeline per Keeper

Each Keeper owns one durable FIFO lane. Board mentions, Task/Goal changes,
Channel and Connector messages, Scheduler events, Job completions, Gate
resolutions, Fusion results, and operator messages enter that lane as typed
stimuli with correlation and source-space identity.

Direct operator/user chat has priority over autonomous observation turns when a
Keeper is idle or finishes a turn (`Keeper_keepalive`). While a turn is running,
a busy Keeper does not lose new input: the stimulus remains durably queued.
Queued chat messages can be edited in place before consumption, and duplicate
acknowledgments on the same thread/stimulus are suppressed. Where a connector
supports an immediate reply, the Keeper may acknowledge that it is busy while
preserving the original stimulus for a later turn.

No Keeper failure or pending request blocks another Keeper lane.

## 2. Cycle

```text
wait for typed stimulus
  -> consume next durable lane item
  -> build source observations
  -> configured LLM decides the next action
  -> execute agent core turn and registered tools
  -> persist transcript, tool results, and receipt
  -> enqueue follow-up stimuli/jobs
  -> wait for the next item
```

FIFO defines delivery order within a stimulus class, with direct chat dequeued
ahead of autonomous heartbeat ticks. The configured LLM decides semantic
relevance, whether to reply, defer, continue existing work, or start another
action. A string classifier, score, timeout strike, progress count, or
hardcoded product name cannot make that decision.

## 3. agent core boundary

MASC supplies agent core with the selected runtime, conversation, multimodal parts,
and the registered tool surface. agent core owns provider/model calls, streaming,
reasoning/tool protocol support, and typed provider outcomes. agent core remains
generic and imports no Keeper, Task, Goal, Board, Connector, or Gate module.

Terminal turn outcomes distinguish explicit model refusal from content-free
stops (`Empty_stop_reason` vs `Refusal_stop_reason`). Empty terminal completion
without visible text or tool effects is recorded as an explicit empty-completion
observation unless the active lane contract permits quiet completion (such as
thinking-only or Muse code-lane turns that completed their side effect via
tools). Provider/model errors return as typed observations. They may cause the
Keeper to choose a fallback runtime on a later action, but they do not
increment a policy strike, create a cooldown, pause the Keeper, or stop its
lane.

## 4. Tool dispatch and Gate

Registered tool descriptors and typed schemas are the tool-surface SSOT. Tool
names, command strings, repositories, vendors, and credential kinds are not
reclassified inside Keeper lifecycle code. When a turn emits multiple tool
calls, producer-prepared resource-bound wave scheduling (`Read` / `Edit` /
`Write` and inline `Skill` recipes) groups non-conflicting operations into
deterministic parallel waves while serializing conflicting resource footprints.

Objective invariants stay at their natural boundary: typed arguments,
`BasePath` containment, sandbox isolation, atomic version checks, and explicit
resource errors.

When an outer product configuration requires a decision, dispatch uses the
generic Gate mode:

- `Always_allow`: dispatch immediately after objective invariants pass;
- `Auto_judge`: the configured LLM returns approve/deny/require-human with
  rationale and provenance;
- `Manual`: persist a nonblocking HITL request and return `Deferred`;
- `Yolo`: operator-persisted bypass mode (`.masc/gate/`) that dispatches
  registered tool effects immediately while recording explicit `yolo` mode
  provenance in the receipt.

There is no separate effect-request domain object, fixed risk class,
privileged floor, product-specific exemption, or hidden authorization
hierarchy. A Gate request references the original registered operation and
carries an exact outer-turn causal-context snapshot (turn-bound approval
context). The Gate stores and forwards that snapshot opaquely without learning
a vendor or tool.

Gate resolution is consumed exactly once and wakes only the originating lane.
The Keeper remains free to perform unrelated work while a request is pending.

## 5. Long-running work

Long-running Tool, Connector, Scheduler, and Fusion activity becomes a Job.
Keepers also own isolated Docker jobs (`keeper_job_start`, `keeper_job_status`,
`keeper_job_output`, `keeper_job_cancel`, `keeper_job_list`) and prepared or
named async tool compositions (`keeper_composition_prepare`,
`keeper_composition_run`, `keeper_composition_status`,
`keeper_composition_cancel`) stored under `.masc/keepers/<name>/jobs/`.
Submitting a Job or async composition returns its durable handle, and owned-job
waits can suspend only the requesting composition step or yield back to the
lane. Completion or failure appends a typed stimulus to the origin lane.
Polling is allowed when the external system has no callback, but polling state
is Job-local and never holds the Keeper fiber or a fleet-wide slot.

## 6. Transcript and observability

Each turn records, in order:

- source stimulus and correlation;
- selected runtime/model and fallback provenance;
- assistant reasoning/thinking parts allowed by the provider contract;
- tool calls, tool results, images/audio/text parts, and interleaving order;
- Gate and Job references (including approval mode and rule renewal expiry);
- terminal agent core outcome (completed, quiet completion, empty stop,
  explicit refusal, or cancellation);
- token, latency, and throughput measurements.

Missing or malformed evidence is an explicit error. A receipt is evidence of
what happened, not authority to pause, retry, or stop the Keeper.

## 7. Lifecycle authority

Only explicit operator stop and durable process-death tombstone end a Keeper
lane. Ordinary provider failure, a pending Gate, an unmet Task/Goal, FD/disk
pressure, no tool call, or lack of recent activity cannot do so. Handoff is
lane-local maintenance and must wake or continue the lane when complete.

## 8. Required invariants

- `INV-TURN-001`: every stimulus is durably queued or returns a typed error.
- `INV-TURN-002`: at most one turn mutates one Keeper timeline at a time.
- `INV-TURN-003`: unrelated Keeper lanes always remain progress-capable.
- `INV-TURN-004`: HITL submission is nonblocking and origin-local.
- `INV-TURN-005`: every tool/provider outcome is explicit and observable.
- `INV-TURN-006`: semantic decisions are configured LLM judgments, not local
  heuristics.
- `INV-TURN-007`: only explicit stop/death owns terminal lifecycle authority.
