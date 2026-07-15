# RFC-0342: Capability catalog overlay, deployment capability declarations, and boot posture

- Status: Draft
- Date: 2026-07-15
- Related: masc#24528 (provider_id stamping fix, merged), oas RFC-OAS-036 / oas#2604
  (D1 overlay + alias-canonicalized lookup, implemented), oas RFC-OAS-034
  (endpoint/capability boundary), masc `codex/catalog-ssot-purge-20260714`
  (`6921f46c98`, vendored-catalog purge, unlanded), RFC-0206 §2.1 (no silent
  fallback)

> 2026-07-15 update: D1 is implemented on the OAS side as RFC-OAS-036
> (`Model_catalog.merge` / `set_global_overlay`, oas#2604). That PR also
> canonicalizes `lookup_for_provider` through the catalog's own `[[providers]]`
> alias data, which makes **D3 optional**: a deployment alias can be declared
> as pure overlay data (a provider entry `id = "vllm-qwen3-mtp"` with
> `aliases = ["runpod_mtp"]`) instead of a masc-side `capability-namespace`
> key. The masc key remains the better ergonomics when the declaration should
> live next to the endpoint in runtime.toml; decide at D3 implementation time.
> Remaining masc-side work: overlay file resolution at bootstrap (after the
> oas release + pin bump), D2, D4.

## 1. Problem

2026-07-15, the server refused to boot: every routed runtime was reported
absent from the OAS capability catalog and startup declined BasePath
ownership. Two defects compounded:

1. **Integration defect (fixed by masc#24528).** The runtime adapter never
   stamped `Provider_config.provider_id`, so `capability_provider_label`
   collapsed every OpenAI-compatible provider into the wire-kind label
   `"openai_compat"`, which no catalog row carries. Under the OAS 0.212
   contract (a declared provider only accepts an exact provider-scoped row;
   bare-row fallback is disabled), no catalog content could satisfy the gate.

2. **Structural defect (this RFC).** Capability truth for a deployment has no
   designed home. The observed consequences, all live in this deployment on
   2026-07-15:
   - Four divergent catalog copies: oas embedded (`models.toml`, build-time),
     `~/.config/oas/models.toml` (symlink to a checkout), the deployment
     config-root `oas-models.toml` (hand-forked, 103 rows / 0 providers,
     three generations of row encodings), and the masc repo-root
     `oas-models.toml` (stale, read by env-coupled tests).
   - Override semantics are replace-not-merge (`Model_catalog.set_global`):
     adding one deployment row requires forking the entire catalog, and the
     fork silently masks every subsequent upstream update. Resolution order
     (config root before embedded) makes the least-maintained copy win.
   - Deployment provider aliases (`runpod_mtp`, `kimi_code`) cannot appear in
     the upstream catalog by design (RFC-OAS-034 §2 rule 1: capability
     namespaces are serving contracts, not hosting aliases), so personal rows
     leaked upstream (`provider_name = "runpod_rtxa6000"`) — the boundary
     violated in the opposite direction.
   - masc's own `[models.X.capabilities]` blocks are parsed and used by
     masc-side validators, but never reach the OAS capability lookup: the
     carrier was deleted during the 0.212 diet ("v1 drops
     runtime_capabilities_override … never consumed",
     `runtime_adapter.ml`). Only `supports_tool_choice` survives. The
     deployment already declares the data the gate then fails to find.
   - A capability-gate failure takes down the whole process, including the
     dashboard that would have shown which rows are missing. The
     fail-closed rationale is sound per binding (2026-06-19 minimax-m3
     corruption via `provider_default` guessing); the process-wide blast
     radius is not.

Interim state after the incident: masc#24528 restores boot, with a
deployment-local full fork (`~/.masc/config/oas-models.toml` = upstream copy +
five alias rows, labeled `WORKAROUND … removal target: overlay RFC merge`).
That fork is the debt this RFC removes.

## 2. Design

### D1. Overlay merge in `Model_catalog` (oas)

`Model_catalog.global ()` becomes `embedded ⊕ overlay`:

- Overlay source: `oas-models-overlay.toml` in the deployment config root
  (same resolution chain as today, minus the full-file `oas-models.toml`
  step). It contains only delta rows and, when needed, delta provider
  entries.
- Merge key: `(provider_name option, id_prefix)` per model row; provider `id`
  per provider entry. Overlay wins on key collision; everything else comes
  from the embedded catalog.
- The full-file replace path stays available for tests via
  `OAS_MODEL_CATALOG` but is deprecated for deployments; masc's
  config-root full-catalog pickup is removed (this is where the
  `catalog-ssot-purge` branch lands: embedded is the only base, the overlay
  is the only deployment input).

Consequence: upstream updates ride along with the pin bump; deployment files
shrink from a 173-row fork to a handful of rows; staleness class disappears.

### D2. Wire `[models.X.capabilities]` into the OAS override (masc)

`Provider_config.model_capabilities_override` exists and is consulted before
any catalog lookup. Restore the carrier: materialization converts a declared
`[models.X.capabilities]` block into a full `Capabilities.capabilities`
value. The conversion must be total — fields the masc schema cannot express
fail the load, they are not defaulted (same Unknown→Permissive bar as the
gate). The capability gate then fires only for bindings that declare
capabilities in neither the catalog nor runtime.toml.

### D3. Alias → serving-contract mapping (masc, small)

`[providers.<id>]` gains an optional key:

```toml
[providers.runpod_mtp]
capability-namespace = "vllm-qwen3-mtp"   # RFC-OAS-034 serving contract
```

When present, materialization stamps `provider_id` with the declared
namespace instead of the table name. This removes every reason for
deployment-alias rows to exist anywhere: `runpod_mtp` resolves through the
upstream `vllm-qwen3-mtp` rows. Absent the key, the table name is used
(masc#24528 behavior).

### D4. Boot posture: lane-blocked, not process-dead (masc)

For catalog-missing routed bindings, startup no longer refuses BasePath
ownership. Instead:

- Runtime init returns a typed `Blocked of missing_catalog_report` state for
  the affected lanes; the control plane (HTTP, dashboard, MCP) boots.
- The dashboard renders the report: per-binding provider label, model id,
  and the exact `provider_name`/`id_prefix` pair a row must declare.
- Dispatch to a blocked runtime fails closed per turn with the same report.
- Full refusal remains only for config *parse* errors (a config we cannot
  read is different from a capability we will not guess).

The per-binding fail-closed guarantee (never dispatch on guessed
capabilities) is unchanged; only the blast radius shrinks.

## 3. Migration

1. masc#24528 (landed first) — gate resolves provider-scoped rows.
2. D3 alias mapping + D2 wiring (masc, independent PRs).
3. D1 overlay (oas PR + release + masc pin bump).
4. Convert the deployment fork: five alias rows → either D3 mappings
   (`runpod_mtp`, `kimi_code`) or overlay delta rows (`glm-coding`
   coding-plan row, local ollama hf.co builds); delete
   `oas-models.toml` fork and the masc repo-root copy; rewrite the eight
   env-coupled `test_runtime_config_validity` cases that still assert
   pre-0.212 prefix-encoded rows (red on main today).
5. D4 boot posture last — it changes operator-visible failure semantics and
   deserves its own review.

## 4. Alternatives considered

- **Keep the full-fork deployment catalog** (today's workaround): every
  upstream change re-rots the fork; three row-encoding generations in the
  previous fork show how this ends.
- **Add alias rows upstream**: violates RFC-OAS-034 §2 rule 1 and reverts
  oas#2432; pollutes a shared catalog with per-deployment hosting names
  (`runpod_rtxa6000` is already there and should migrate out via D1/D3).
- **Re-enable bare-row fallback for declared providers**: reintroduces the
  exact corruption the gate exists to prevent (native Kimi vs Ollama-Cloud
  Kimi capability divergence; 2026-06-19 incident).
- **Permissive default for unknown models**: rejected outright
  (Unknown→Permissive anti-pattern, RFC-0206 §2.1).

## 5. Test plan

- Overlay: unit tests for merge precedence (embedded row vs overlay row,
  provider-scoped vs bare), empty overlay, provider-entry overlay.
- D2: total-conversion property — every declarable masc capability field maps
  to the OAS field; a schema field with no OAS counterpart fails load.
- D3: binding with `capability-namespace` resolves upstream serving-contract
  rows; without it, table-name behavior is unchanged (masc#24528 tests).
- D4: boot with a catalog-missing routed binding → control plane healthy,
  lane blocked, dashboard report present, dispatch returns the typed error.
