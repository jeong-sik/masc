# Keeper Skill use proof

## Problem

An available Skill is not evidence that a Keeper used it. The runtime must keep
these facts separate:

1. the exact Skill was offered to the Keeper;
2. the model invoked `keeper_skill`;
3. the runtime produced the frozen body;
4. a later provider request contained that tool result; and
5. the model subsequently chose an action while that body was in its input.

The evidence records facts. It does not force a Keeper to activate a Skill and
does not gate later tool calls.

## Identity

One use is identified by the tuple below. No name-only or body-text matching is
allowed.

```text
(workspace_key, session_id, snapshot_revision, turn_ref, invocation_runtime_id,
 skill_reference, skill_tool_use_id)
```

`skill_reference` contains the source, package, canonical name, and exact
`SKILL.md` content revision. `skill_tool_use_id` is the Agent Core invocation
identifier that also appears on the provider-bound `ToolResult`.

## States and observations

```text
Offered
  -> Content_served (Body | Resource | Composition invocation)
       -> Content_delivered
            -> Action_observed *
```

- `Offered` is projected from the frozen turn snapshot and effective tool
  surface. It is not stored as a use.
- `Content_served` is stored only after the exact-reference handler has built a
  provider-inline result. Body and resource record byte count and digest;
  composition invocation is a distinct constructor, never an empty body.
- `Content_delivered` has two typed boundaries. Agent Core first stages an exact
  `(tool_use_id, content bytes, content SHA-256)` receipt from the final
  provider projection and commits it only after that request returns a model
  response. Official clients commit the same receipt when the common dynamic
  tool host hands the result back to the client. A pre-projection message,
  serializer attempt, or provider failure is not delivery.
- `Action_observed` records each later model-selected tool invocation in the
  same Keeper turn. It proves ordering and context availability, not an LLM's
  private causal reasoning.

Invocation, delivery, and action each retain their observed runtime identity.
A failover may therefore invoke on runtime A and deliver or act on runtime B;
operator projections must not relabel those later facts as runtime A.

Failures remain explicit. Served content without a matching later request stays
served; it is never projected as delivered. Rejected delivery/action transitions
are append-only typed observations and contribute to the displayed invalid count.

## Durable authority

The session Skill-use ledger is the authority for use facts. Tool-call logs,
TurnRecords, Dashboard, and TUI carry ledger identities or projections; they do
not recreate use state from text or timestamps.

The ledger is rewritten atomically under the existing Keeper session lock. A
repeated observer for the same typed identity is idempotent. Distinct
`skill_tool_use_id` values remain distinct uses, even for the same Skill.

## Resource disclosure

The instruction body and bundled resources have separate observations.

- `keeper_skill(reference)` serves the frozen `SKILL.md` body.
- `keeper_skill(reference, file)` serves one relative regular file from the
  exact package root.
- absolute paths, empty components, `.`/`..`, symlinks, directories, and files
  above the turn snapshot's positive
  `[skills].resource-read-max-bytes` value are rejected before content or an
  activation is returned.
- a resource result records its relative path and exact content digest.
- the model-facing result content is the raw body/resource bytes. Exact reference,
  path, byte count, and digest travel as typed metadata and ledger evidence, so
  JSON envelope escaping cannot silently turn an accepted resource into a blob
  marker. Content that cannot fit the shared provider-inline boundary is rejected
  before activation recording.

Resource bytes are read only on the resource call. They are not placed in the
catalog snapshot or the initial Keeper prompt.

## Runtime configuration

Skill source roots and their order come only from `[skills]` in `runtime.toml`.
The source `access` value must affect write admission before `read-write` is
advertised. A configuration value with no runtime consumer must not be exposed
as an effective setting.

The Dashboard may edit the canonical `runtime.toml`; the TUI and Dashboard must
show the same config-application receipt and Skill snapshot revision.

## Quantitative completion criteria

One exact-head Keeper run passes only when all counts below come from the same
workspace, session, Keeper turn, and Skill reference. Invocation, delivery,
and action runtime identities are compared as separate dimensions:

| Measurement | Required |
|---|---:|
| offered exact Skills | at least 1 |
| distinct `keeper_skill` invocations | at least 1 |
| bodies + resources served | equal to successful instruction invocations |
| content delivered to provider input | equal to served content selected for proof |
| later model-selected tool actions | at least 1 |
| unmatched or invalid use transitions | 0 |
| Dashboard decode errors | 0 |
| TUI decode errors | 0 |

The proof is repeated in three ways:

1. a deterministic handler test proves exact-reference and persistence wiring;
2. a real Keeper task proves natural model activation and a later action; and
3. a runtime A-to-B retry proves the same frozen Skill reference survives
   provider failover.

Session totals are operational context, not a proof row. Browser and TUI captures
must group proof counts by the same snapshot revision, turn reference,
invocation runtime, and exact Skill reference; they must also display delivery
and action runtime counts, source commit, and session id.
