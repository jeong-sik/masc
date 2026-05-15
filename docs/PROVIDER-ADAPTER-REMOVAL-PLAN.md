---
status: draft
last_verified: 2026-05-15
code_refs:
  - lib/provider_runtime_projection.ml
  - lib/provider_tool_support.ml
  - scripts/lint/provider-adapter-removal-ratchet.sh
  - docs/OAS-MASC-BOUNDARY.md
  - docs/rfc/RFC-0058-declarative-cascade-config.md
  - docs/rfc/RFC-0072-provider-adapter-sublib-extraction.md
---

# Provider Adapter Removal Plan

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
| Runbook | `docs/PROVIDER-ADAPTER-RUNBOOK.md` | describes current compatibility state, not the target SSOT |

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

### Phase 0 - Freeze The Old Boundary

Goal: stop making `Provider_adapter` larger.

- Mark `docs/PROVIDER-ADAPTER-RUNBOOK.md` as current compatibility, not future SSOT.
- Add a lint rule that fails new public `Provider_adapter.` callers outside an
  explicit allowlist.
- Keep `scripts/lint/no-provider-name-hardcoding.sh --fail`, but treat its
  `Provider_adapter` allowlist as temporary debt, not a safe harbor.
- Keep the ratchet pinned at zero `lib/provider_adapter.mli` exports.
- Wire `scripts/lint/provider-adapter-removal-ratchet.sh` into Fundamental
  Check so the freeze runs on every PR.

Exit criteria:

- new PRs cannot add provider/model literals outside OAS/catalog or an approved
  MASC-local overlay file
- new PRs cannot add `Provider_adapter.` callers without touching the removal
  allowlist and explaining why

### Phase 1 - Move Read-Only Runtime Truth To OAS Inputs

Goal: replace registry reads with OAS-owned catalog/capability reads.

- Replace `direct_adapters` reads with a runtime binding list built from OAS
  catalog/capability data.
- Move alias/canonical-name resolution to OAS catalog lookup.
- Move model default and auto-model expansion to OAS catalog/capability surfaces.
- Keep only MASC-local overlays for lane naming, spawn, auth display, telemetry
  redaction, and runtime-MCP behavior.

Exit criteria:

- `direct_adapters` no longer decides provider/model availability
- adding a provider/model via OAS catalog is visible to MASC without changing
  `lib/provider_adapter.ml`
- provider/model labels are opaque at MASC product boundaries

### Phase 2 - Replace Caller Groups

Goal: remove caller dependence by ownership group, not by mechanical rename.

| Caller group | Replacement |
|---|---|
| `lib/cascade/*` model/label resolution | runtime binding + capability requirement API |
| `lib/provider_tool_support*` | OAS capability query + MASC runtime-MCP local policy |
| `lib/spawn.ml` / auto responder | spawn overlay keyed by opaque runtime id |
| worker docker/auth env | credential projection from OAS binding plus MASC injection rules |
| dashboard/provider runs | neutral runtime lane/status projection |
| voice bridge | separate voice endpoint catalog or local voice overlay |
| tests | boundary tests that forbid raw provider/model identity at MASC surfaces |

Exit criteria:

- `rg -l 'Provider_adapter\\.' lib test bin` is limited to compat tests and the
  temporary shim
- cascade routing tests prove capability/lane routing without vendor literals
- dashboard tests prove provider/model identity remains neutralized

### Phase 3 - Delete The Compiled Catalog

Goal: remove the internal implementation.

- Delete legacy canonical provider-name values from MASC.
- Delete `direct_adapters`.
- Delete provider/model default lists from MASC.
- Delete provider-kind reverse lookup helpers from MASC.
- Delete provider auth/capability rules that duplicate OAS registry data.
- Keep any MASC-local runtime quirks in data-driven local policy with no
  concrete provider catalog.

Exit criteria:

- `lib/provider_adapter.ml` does not contain provider/model catalog data
- `lib/provider_adapter.mli` is gone or only re-exports deprecated shim functions
- no MASC code branches on concrete vendor/model literals for routing
- no OAS-owned provider/model identity is shown in keeper runtime products

### Phase 4 - Remove The Shim

Goal: no provider adapter module remains.

- Rename remaining compatibility references to the owning modules.
- Delete `Provider_adapter_compat`.
- Delete allowlist entries that existed only for `Provider_adapter`.
- Retire `docs/PROVIDER-ADAPTER-RUNBOOK.md` or convert it to a historical note.

Exit criteria:

- `rg 'Provider_adapter' lib test bin docs scripts` has no live implementation
  references except historical docs
- adding a provider/model is an OAS/catalog change only

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

Start with a docs/test/lint slice, not a broad runtime rewrite:

1. Add this removal plan.
2. Mark `docs/PROVIDER-ADAPTER-RUNBOOK.md` as compatibility-only.
3. Add `scripts/lint/provider-adapter-removal-ratchet.callers` for
   `rg -l 'Provider_adapter\\.' lib test bin`.
4. Add `scripts/lint/provider-adapter-removal-ratchet.exports` for the current
   `.mli` export count.
5. Add `scripts/lint/provider-adapter-removal-ratchet.sh` and wire it to
   `.github/workflows/fundamental-check.yml`.

This creates a ratchet before moving runtime behavior.

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
