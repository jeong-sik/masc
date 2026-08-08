# SDK Independence Principle

## Rule

OAS (OCaml Agent SDK) does not contain domain vocabulary from any specific
downstream coordinator. The dependency direction is strictly:

```
MCP Protocol SDK  <--  OAS (Agent SDK)  <--  External coordinator
```

OAS provides generic single-agent primitives: context, hooks, tool/runtime
abstractions, and provider-neutral runtime events. Coordinators consume these
primitives and add their own query classification and orchestration semantics.
OAS is not allowed to name, depend on, or adapt to any specific coordinator.

## What this means in practice

1. **No coordinator-specific classifiers.** Terms like "keeper", "room",
   "broadcast", or coordinator-specific role names must not appear in OAS
   keyword lists or prompt templates.

2. **No coordinator types imported.** OAS must never depend on a coordinator's
   opam package or reference coordinator-specific module names.

3. **Generic vocabulary only.** Where OAS needs coordination-related language
   in generic documentation or protocol descriptions, use domain-neutral terms:
   "assign", "route", "transfer", "coordinate", "sync", "notify", "actor",
   "group".

4. **Query-intent classification lives downstream.** A coordinator that needs
   terms such as "handoff" must own a typed classifier and its failure policy.
   OAS intentionally provides no heuristic compatibility adapter.

5. **Provider catalogs stay generic.** Explicitly installed
   `Provider_catalog` entries may describe provider ids, transport, auth mode,
   endpoint, default model, and capabilities. They must not encode
   coordinator-owned routing concepts such as keeper, room, tier-group, board,
   governance queue, or dashboard policy.

## Module ownership (this repository only)

This table is restricted to OAS-owned modules. Whatever a downstream
coordinator wraps these in is intentionally outside this document.

| Module | Owner |
|--------|-------|
| `Contract`, `Completion_contract` | OAS |
| `Guardrails_async` | OAS |
| `Runtime`, `Runtime_store` | OAS |
| `Raw_trace`, `Sessions` | OAS |

Product-specific governance, adjudication, and proof modules belong to the
calling product's repository. OAS does not model or track those concepts.

## Enforcement

- CI: the unbounded-agent contract ratchet prevents deleted runtime-policy
  surfaces from re-entering executable SDK code.
- Code review: query-intent keyword scoring and silent fallback classifiers do
  not belong in OAS.
- README and top-level docs must not mention any specific external coordinator
  by name.

## History

- 2026-03-29: Initial principle established. Removed downstream vocabulary from
  the former context-intent classifier and replaced it with generic terms.
- 2026-04-17: Tightened. Owner/consumers table no longer names downstream
  coordinators; OAS docs do not depend on any specific consumer.
- 2026-05-21: Removed stale CDAL module ownership after the 0.193.0 migration;
  proof artifacts are schema-level interoperability contracts, not OAS OCaml
  modules.
- 2026-07-08: Removed the public query-intent classifier. The 0.209 migration
  guide records the safety exception to the usual deprecation window.
