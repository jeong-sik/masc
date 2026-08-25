# API Stability Tiers

OAS (OCaml Agent SDK) modules are classified into three stability tiers.
Public facade modules carry a `@stability` annotation in their top-level doc
comment; unannotated modules are Internal by default.

## Tiers

| Tier | Promise | Breaking change policy |
|------|---------|----------------------|
| **Stable** | Backward-compatible within a major version. | Requires major version bump + migration guide. |
| **Evolving** | May change with deprecation notice. | One minor-version deprecation window before removal. |
| **Internal** | Implementation detail. No stability promise. | May change in any release without notice. |

## Classification criteria

### Stable

- Types and functions that downstream consumers (external coordinators, embedding agents) import directly.
- Core abstractions: `Types`, `Error`, `Agent`, `Builder`, `Tool`, `Provider`, `Hooks`.
- Breaking a Stable module breaks all consumers.

### Evolving

- Modules under active development with external consumers.
- New features (runtime evidence, structured output, harness) that have not yet settled.
- Runtime orchestration helpers whose API is still being refined.

### Internal

- Modules not intended for direct external use.
- LLM provider backends, protocol internals, parse/serialize helpers.
- Sub-modules of agent/ that are implementation details of Agent.

## Annotation format

An explicitly classified `.mli` file has a top-level doc comment with the
`@stability` tag:

```ocaml
(** Context management for agent conversations.

    @stability Stable
    @since 0.93.1 *)
```

Rules:
- At most one `@stability` tag per `.mli` file, at the top-level module doc comment.
- `@since` indicates the version when the stability tier was assigned (not when the module was created).
- Modules without `@stability` are treated as **Internal** by default.
- Promotion (Internal -> Evolving -> Stable) does not require deprecation.
- Demotion (Stable -> Evolving) requires one minor version of deprecation.

## Current classification

The public facade modules classified below carry an explicit stability tier.

### Stable modules

Core types and interfaces that downstream consumers depend on.

| Module | File |
|--------|------|
| Types | `lib/base/types.mli` |
| Error | `lib/base/error.mli` |
| Agent | `lib/agent/agent.mli` |
| Builder | `lib/agent/builder.mli` |
| Tool | `lib/base/tool.mli` |
| Tool_set | `lib/tool_set.mli` |
| Hooks | `lib/base/hooks.mli` |
| Provider | `lib/provider.mli` |
| Raw_trace | `lib/raw_trace.mli` |
| Checkpoint | `lib/checkpoint.mli` |
| Checkpoint_store | `lib/checkpoint_store.mli` |
| Context | `lib/base/context.mli` |

### Evolving modules

Public modules with downstream consumers that are still settling. This tier
includes most top-level SDK surfaces outside the stable core.

Representative modules:

| Module | File | Reason |
|--------|------|--------|
| Runtime | `lib/runtime.mli` | Runtime protocol types are still evolving |
| Wire_observer | `lib/llm_provider/wire_observer.mli` | Caller-owned wire observation boundary is still evolving |

CDAL proof-bundle artifacts are intentionally schema-only in OAS. They are
tracked in `docs/schema-surfaces/runtime-output-surfaces.v1.json`, not as
public OCaml modules in this stability table.

### Removed surfaces

The legacy request-dispatch island — superseded by `Llm_provider.Complete` —
was removed (2026-07-21) after its one minor-version deprecation window:

- `Api.create_message` / `Api.create_message_detailed` (was `lib/api.mli`)
- `Streaming.create_message_stream` / `Streaming.create_message_stream_detailed` (was `lib/streaming.mli`)
- All of `Provider_intf` (was `lib/provider_intf.mli`)
- The rest of `Api`/`Api_anthropic`/`Api_openai`/`Api_common`/`Streaming`
  (request body builders, response parsers, JSON codecs such as
  `content_block_to_json` / `content_block_of_json`, the stream accumulator
  re-export) — these were not themselves deprecated, but existed only as a
  facade over `Llm_provider`; call sites now use the `Llm_provider` modules
  (`Api_common`, `Backend_anthropic`, `Backend_openai`, `Backend_openai_parse`,
  `Streaming`, `Complete_stream_acc`) directly.

### Internal modules

Implementation-detail modules with no compatibility promise. Most entries in
this tier live under internal subdirectories such as `lib/agent/`,
`lib/protocol/`, and `lib/llm_provider/`, plus parser/transport helpers that
external consumers should not depend on directly.

#### Execution-journal migration boundary

`Execution_event` and `Execution_journal` are private implementation modules.
They are not re-exported by `Agent_sdk`, are not an external extension point,
and have no supported writer API. Their repository-local regression suite uses
Dune's internal library alias; that alias is not a supported external API
contract.

This classification does not claim a runtime behavior upgrade. The single-writer
hard cut this section used to describe as future work has landed (#2683): the
OAS execution path (`Agent_execution_runner` / `Execution_agent_scope`) owns
occurrence creation, surfaced through the public `Agent.execution_store` API.
`Durable_event` remains as the journal type and idempotency-key foundation
(`agent_execution_event_writer`, `agent_tools`) — not as an independent second
writer. Event_bus, Raw_trace, durable persistence, and downstream dashboard
data consume read projections. There must be no interval in which two
components independently author the same execution history.

## Verification

```bash
# List every explicitly classified interface
rg '@stability' lib/ --glob '*.mli' -l

# List by tier
rg '@stability Stable' lib/ --glob '*.mli' -l
rg '@stability Evolving' lib/ --glob '*.mli' -l
rg '@stability Internal' lib/ --glob '*.mli' -l
```
