---
status: reference
last_verified: 2026-07-13
code_refs:
  - lib/workspace/
  - lib/workspace_goals.ml
  - lib/goal/
  - lib/task/tool_task.ml
  - lib/tool_agent.ml
  - lib/workspace/workspace_git.ml
  - lib/workspace/workspace_task_claim.ml
---

# Workspace State

> Part of: [SPEC-INDEX](./SPEC-INDEX.md)

## 1. Boundary

Workspace is the durable collaboration boundary for Keepers. It owns typed
identity and storage for Keeper, Task, Goal, Board, Channel, Connector, Job,
Gate, Fusion, and their correlations. It does not own provider/model execution;
MASC calls OAS for that boundary and OAS does not import MASC concepts.

Every path is resolved from the caller's `BasePath`. A repository, connector,
credential, vendor, or command name is data supplied through a registered
boundary, never a branch in Workspace policy.

## 2. State ownership

| Concept | Authoritative state | Coupling rule |
|---|---|---|
| Keeper | identity plus durable lane reference | one lane per Keeper |
| Task | typed state, owner, version, evidence references | may reference a Goal; never embeds Goal policy |
| Goal | objective, typed state, version, Task references | Task results arrive as observations |
| Board | posts, comments, reactions, mentions | publishes typed stimuli; never mutates Keeper lifecycle |
| Channel / Connector | scoped external conversation identity | space and participant identity remain explicit |
| Job | asynchronous work handle and result | completion wakes the originating lane |
| Gate | durable pending/resolved decision | never blocks unrelated work or another Keeper lane |
| Fusion | panel, runs, results, Judge result | asynchronous Job; no quorum authority |

Cross-domain references are typed ids with explicit versions. There is no
shared status string that silently changes another domain.

## 3. Atomic mutation contract

All mutations follow one contract:

1. parse typed input at the protocol boundary;
2. load the current object and version;
3. validate objective invariants such as id shape, ownership, and legal state
   transition;
4. commit with compare-and-swap or an atomic file replacement;
5. return a typed success, conflict, or storage error and emit the same result
   to observability.

Decode, storage, and conflict failures are never converted to empty state or a
successful response.

## 4. Task claim and selection

Task claim is an explicit, versioned mutation. A claim is not released,
archived, re-prioritized, or reassigned because elapsed time crossed a threshold.
Only an explicit release/transition can change it.

When semantic selection is requested, the configured LLM receives the typed
candidate snapshot and returns a Task id, expected version, rationale, and
evidence references. Workspace then attempts that exact claim atomically. A
conflict is returned to the Keeper for another judgment; Workspace does not
silently choose a different Task.

Numeric priority may be stored only as explicit user data. It is not an
authorization rule or an automatic scheduler.

## 5. Goal and Task lifecycle

Goal and Task remain weakly coupled. Completing a Task records its result and
publishes a typed stimulus to the Goal owner. It does not complete the Goal.

Semantic completion uses the configured LLM:

```text
Executing
  -> Awaiting_llm_judgment
  -> Executing | Completed | Dropped
```

The judgment input contains the Goal, related Tasks, Board/Job evidence, and
the expected Goal version. The judgment result records verdict, rationale,
model/runtime provenance, and evidence references. Workspace applies the
verdict only if the version still matches.

Optional HITL is a separate nonblocking Gate. Submitting a Gate request returns
`Deferred`; the Keeper can continue other work. Resolution is durable and wakes
only the originating Keeper lane. There is no verifier rank, N-of-M quorum,
risk level, privileged override, or global pause.

## 6. Presence and failure observations

Heartbeat and process/fiber state are observations, not lifecycle guesses.
Elapsed time alone does not create `Zombie`, release Task ownership, stop a
Keeper, or suppress a turn. An explicit operator stop or durable process-death
tombstone is recorded as its own event.

Failure of one Keeper, Job, Connector, Gate request, or storage operation is
scoped to that object and lane. It cannot pause the Workspace or other Keepers.

## 7. Required invariants

- `INV-WORKSPACE-001`: every mutation is versioned and atomic.
- `INV-WORKSPACE-002`: every error is typed and observable.
- `INV-WORKSPACE-003`: Task claim changes only through an explicit mutation.
- `INV-WORKSPACE-004`: Goal completion requires configured LLM judgment and
  matching version.
- `INV-WORKSPACE-005`: Gate submission never blocks the originating lane.
- `INV-WORKSPACE-006`: Gate resolution wakes only its origin lane.
- `INV-WORKSPACE-007`: no observation automatically pauses or stops a Keeper.
- `INV-WORKSPACE-008`: all filesystem locations derive from `BasePath`.

## 8. Retired contracts

The following are not part of Workspace state: global pause/resume, claim TTL,
stale-claim auto-release, zombie time thresholds, starvation/priority boosts,
speculation budgets, reputation scores, risk tiers, and product-specific
authorization tables.
