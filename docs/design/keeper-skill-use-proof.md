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
(workspace_key, session_id, turn_ref, skill_reference, skill_tool_use_id)
```

`skill_reference` contains the source, package, canonical name, and exact
`SKILL.md` content revision. `skill_tool_use_id` is the Agent Core invocation
identifier that also appears on the provider-bound `ToolResult`.

## States and observations

```text
Offered
  -> Body_served
       -> Body_delivered
            -> Action_observed *
```

- `Offered` is projected from the frozen turn snapshot and effective tool
  surface. It is not stored as a use.
- `Body_served` is stored after the exact-reference handler has built a
  successful body result. It records the result byte count and digest.
- `Body_delivered` is stored only when a later provider request contains the
  matching `ToolResult.tool_use_id`.
- `Action_observed` records each later model-selected tool invocation in the
  same Keeper turn. It proves ordering and context availability, not an LLM's
  private causal reasoning.

Failures remain explicit. A served body without a matching later request stays
`Body_served`; it is never projected as delivered.

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
  above the declared size limit are rejected before content is returned.
- a resource result records its relative path and exact content digest.

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
workspace, session, Keeper turn, runtime, and Skill reference:

| Measurement | Required |
|---|---:|
| offered exact Skills | at least 1 |
| distinct `keeper_skill` invocations | at least 1 |
| bodies served | equal to successful invocations |
| bodies delivered to provider input | equal to bodies served |
| later model-selected tool actions | at least 1 |
| unmatched or invalid use transitions | 0 |
| Dashboard decode errors | 0 |
| TUI decode errors | 0 |

The proof is repeated in three ways:

1. a deterministic handler test proves exact-reference and persistence wiring;
2. a real Keeper task proves natural model activation and a later action; and
3. a runtime A-to-B retry proves the same frozen Skill reference survives
   provider failover.

Browser and TUI captures must display the exact source commit, runtime id,
session id, turn reference, Skill revision, and the five counts above.
