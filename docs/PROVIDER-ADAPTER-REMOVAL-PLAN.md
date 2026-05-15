---
status: reference
last_verified: 2026-05-15
code_refs:
  - lib/provider_runtime_projection.ml
  - lib/provider_tool_support.ml
  - scripts/lint/provider-adapter-removal-ratchet.sh
  - docs/OAS-MASC-BOUNDARY.md
  - docs/rfc/RFC-0058-declarative-cascade-config.md
---

# Provider Adapter Removal Record

This plan tracks removal of the MASC-owned `Provider_adapter` implementation.
As of 2026-05-15, the compiled `Provider_adapter` module is deleted. It is
intentionally a removal plan, not another centralization pass.

## Objective

Delete the compiled provider/model catalog from `masc-mcp`.

`masc-mcp` may keep runtime-local projection code for cascade labels, spawn keys,
auth display, telemetry policy, runtime-MCP quirks, and voice defaults. It must
not own provider/model identity, aliases, canonical provider names, model defaults,
or concrete provider capability truth.

The target state is:

- OAS owns concrete provider/model identity through provider catalog and capability
  manifest surfaces.
- MASC consumes OAS provider bindings as opaque runtime records.
- MASC policy code routes by logical lane, capability requirements, health,
  capacity, receipt state, and operator intent.
- Adding a concrete provider or model does not require editing or rebuilding
  `masc-mcp`.
- `lib/provider_adapter.ml` and `lib/provider_adapter.mli` are removed, or reduced
  to a temporary compatibility shim with a deletion date and no internal catalog.

## Current Inventory

Verified on 2026-05-15:

| Surface | Current state | Removal meaning |
|---|---:|---|
| `lib/provider_adapter.ml` | absent | compiled provider registry deleted |
| `lib/provider_adapter.mli` | absent | public provider identity/capability surface deleted |
| External `Provider_adapter.` callers | 0 files in `lib/` and `bin/` | production callers no longer depend on this boundary |
| Public canonical provider names | 0 exports | provider ids are no longer compiled through this module |
| Adapter registry | absent | aliases, prefixes, defaults, auth, capabilities moved to OAS/runtime projection surfaces |
| Runbook | removed | old compatibility matrix deleted; use this record plus `docs/OAS-MASC-BOUNDARY.md` |

The deleted `.mli` mixed these responsibilities:

- common types and string converters
- direct adapter registry
- label/model parsing
- provider-kind bridging
- auth/env-key projection
- OAS capability bridging
- runtime-MCP tool policy
- voice adapter routing
- legacy compatibility helpers

Those are different ownership layers. Splitting the file without moving ownership
out of MASC would preserve the bug.

## Ownership Split

| Responsibility | Owner after removal | Notes |
|---|---|---|
| Provider ids, aliases, model defaults | OAS | Use provider catalog / capability manifest, not MASC literals |
| Provider capability truth | OAS | Tool support, transport class, model features, pricing/cost surfaces |
| Runtime credentials contract | OAS for provider semantics; MASC for local injection policy | MASC may decide how to pass secrets into its workers, not what a provider means |
| Cascade lane and profile intent | MASC | Logical use case, not concrete vendor/model identity |
| Health/capacity state | MASC runtime state over opaque runtime ids | Do not branch on vendor literals |
| Spawn key mapping | MASC local overlay | Should be data-driven from runtime entries where possible |
| Runtime-MCP quirks | MASC local overlay | Only for MASC tool/auth transport behavior; no provider catalog ownership |
| Voice defaults | MASC local overlay until voice has its own catalog | Must not keep direct LLM provider catalog alive |
| Compatibility field redaction | MASC | Legacy `provider`/`model` keys may remain with neutral/null values |

## Target Shape

Use OAS runtime bindings directly. If MASC needs a local policy projection,
keep it as data derived at the call site or from a MASC-owned config file,
not as a provider catalog facade:

```ocaml
module Runtime_binding = Agent_sdk.Provider_runtime_binding
```

The implementation must not contain a concrete provider catalog. It should be
constructed from OAS provider catalog/capability surfaces plus MASC-local policy
configuration. MASC can enrich opaque runtime entries with local policy,
but it cannot invent provider/model truth.

The remaining compatibility module, if needed, should look like this:

```ocaml
module Provider_adapter_compat : sig
  val provider_model_label : string -> string -> string option
  val default_cli_agent_name : unit -> string
end
```

Every compat function must have a planned deletion issue or PR slice. No new
callers may be added.

## Migration Phases

Completed phases:

- Freeze guard: `scripts/lint/provider-adapter-removal-ratchet.sh` pins new
  `Provider_adapter` callers/exports.
- Runtime ownership: provider/model truth moved out of the compiled MASC
  adapter boundary; runtime-local projection remains in
  `lib/provider_runtime_projection.ml` and `lib/provider_tool_support.ml`.
- Compiled catalog deletion: `lib/provider_adapter.ml` and
  `lib/provider_adapter.mli` are absent.
- Historical runbook/RFC cleanup: the old provider-adapter runbook and stale
  extraction RFC were removed after the compiled module disappeared.

Remaining work is guard-only unless code reintroduces a MASC-owned provider
catalog.

### Guard Rails

- new PRs must not add provider/model literals outside OAS/catalog or an
  approved MASC-local overlay file
- new PRs must not add `Provider_adapter.` callers without failing the ratchet
- direct provider/model identity must stay neutralized at MASC product
  boundaries

| Caller group | Replacement |
|---|---|
| `lib/cascade/*` model/label resolution | runtime binding + capability requirement API |
| `lib/provider_tool_support*` | OAS capability query + MASC runtime-MCP local policy |
| `lib/spawn.ml` / auto responder | spawn overlay keyed by opaque runtime id |
| worker docker/auth env | credential projection from OAS binding plus MASC injection rules |
| dashboard/provider runs | neutral runtime lane/status projection |
| voice bridge | separate voice endpoint catalog or local voice overlay |
| tests | boundary tests that forbid raw provider/model identity at MASC surfaces |

## Validation Gates

Use these gates per phase:

```bash
scripts/lint/provider-adapter-removal-ratchet.sh
rg -l 'Provider_adapter\.' lib test bin
test ! -e lib/provider_adapter.ml
test ! -e lib/provider_adapter.mli
scripts/lint/no-provider-name-hardcoding.sh --fail
git diff --check
```

For code phases, use focused build targets rather than full `dune build`:

```bash
scripts/dune-local.sh build lib/masc_mcp.a
scripts/dune-local.sh build test/test_observability_provider_contracts.exe
scripts/dune-local.sh build test/test_provider_prefix_boundary.exe
```

Add or keep tests that prove:

- OAS catalog entries can supply aliases and defaults without MASC code edits.
- MASC cannot resolve provider/model identity from legacy product payloads.
- runtime-MCP local quirks are keyed through local policy, not provider names.
- no new direct `Provider_adapter.` caller appears without an explicit migration
  waiver.

## First PR Slice

Completed. Keep this section as historical context only; do not use it as a
current implementation checklist.

## Open Questions

- Which exact OAS provider catalog API should MASC consume for runtime bindings:
  in-process OCaml API only, generated manifest, or both?
- Should voice runtime policy move to the same OAS catalog, or to a separate
  voice endpoint catalog owned by MASC?
- Which legacy `provider` / `model` JSON keys are still client-visible and must
  remain as neutral compatibility fields during Phase 2?
- Which `Provider_config.provider_kind` bridges are still required by current
  OAS API shape, and which require upstream OAS changes before MASC deletion?

## Completion Definition

The removal is complete only when:

- the MASC repo has no compiled provider/model catalog
- `Provider_adapter` is absent from live code
- OAS catalog/capability data is the only concrete provider/model truth source
- MASC runtime and dashboard products remain provider/model-neutral
- tests and lint enforce the boundary so the catalog cannot grow back
