# RFC-0066 — Legacy `*_models` Catalog Purge

**Status**: Draft
**Author**: jeong-sik (with Claude Opus 4.7)
**Date**: 2026-05-11
**Supersedes**: —
**Related**:
- RFC-0058 (declarative cascade config) — established the 5-layer declarative schema this RFC is the closeout phase for
- Issue #14624 (architectural: `Keeper_config.default_cascade_name` init-time cache + legacy catalog declarative-blindness) — root-cause tracker this RFC retires
- PR #14611, #14616, #14620, #14623 (Phase 9.3 fallout sweep) — test-side patches that surfaced the dependency

---

## 1. Problem

After RFC-0058 §9 (Phase 9.1–9.4) eliminated the on-disk `cascade.json`, the codebase still carries a *legacy catalog discovery* path that scans flat `<profile>_models` JSON keys emitted by the materializer's per-profile fallback layout. Production `cascade.toml` has migrated entirely to the declarative `[providers.X]` / `[tier-group.X]` namespaces; the legacy `Cascade_config_loader.load_catalog` returns `[]` on every production read.

The mismatch causes a known production divergence:

| Layer | Production result | Test result (per-profile fixture) |
|---|---|---|
| `Cascade_catalog_runtime` (declarative path) | `"big_three"` (live snapshot) | `"big_three"` (legacy reader sees flat key) |
| `Keeper_config.default_cascade_name` (legacy path, init-time cached) | `"default"` (catalog empty at init) | `"big_three"` |

18 production call sites of `Keeper_config.default_cascade_name` therefore reference a stale fallback that has no corresponding entry in the live catalog: `Keeper_turn_cascade_budget` comparisons never match, `Keeper_turn_up_create/update` defaults to an invalid cascade name, `Dashboard_cascade` advertises a non-existent profile in `config_path` defaults, and so on. Six Pattern C test failures in PR #14620 are the visible symptom; #14624 documents the layered cause.

A surgical fix (route `Keeper_config.default_cascade_name` through `Cascade_catalog_runtime`) does not close the gap: `lookup_active_profile` falls back to `normalize_declared_name` which calls `cascade_name_for_use`, which itself reads the legacy catalog. The mismatch survives unless the legacy path is removed.

### Goal

Delete `Cascade_config_loader.load_catalog` / `load_profile_weighted` / `load_profile` and their `<profile>_models` materializer arm. Migrate every reader to `Cascade_catalog_runtime` (the live snapshot, declarative-aware). Treat the declarative schema as the sole catalog source of truth.

### Non-goals

- Changing the dashboard UX or any operator-visible behavior. The transition should be invisible at runtime.
- Touching the SDK / hook / agent boundary contracts.
- Renaming RFC-0058 namespaces or fields. The migration only deletes the *legacy reader*, not the declarative schema.

---

## 2. Current state

### 2.1 Legacy catalog API

`lib/cascade/cascade_config_loader.ml`:
- `load_catalog : config_path:string -> (catalog_entry list, string) result` — scans `<name>_models` keys at the root of the materialized JSON.
- `load_profile_weighted : config_path:string -> name:string -> weighted_entry list` — pulls the `<name>_models` array, parses each item.
- `load_profile : config_path:string -> name:string -> string list` — derived from `load_profile_weighted`.
- `load_cascade_profile_flat_models` (internal, RFC-0058 §9.4 rename) — `cascade_profile` shape from flat keys.
- `is_deprecated_logical_profile_name` — filters route-alias names out of catalog discovery.

`lib/cascade/cascade_toml_materializer.ml:404`:
- Per-profile field arm `models = [...]` → JSON `<profile>_models = [...]`. Emitted only when an operator authors a `[<profile>]\nmodels = [...]` block. Production has none.

### 2.2 Production cascade.toml shape

Inspected `config/cascade.toml` at HEAD `49566db3d` (2026-05-11): top-level namespaces are exclusively `providers.`, `models.`, `routes.`, `tier.`, `tier-group.`, `profiles.`. Zero per-profile `[X]\nmodels = [...]` blocks. The flat materializer arm contributes nothing to the production runtime path.

### 2.3 Live declarative reader

`lib/cascade/cascade_catalog_runtime.ml` already loads `cascade.toml` through `Cascade_declarative_hotpath.try_load_declarative`, validates it, and exposes:
- `known_profile_names : ?sw/net/clock:_ -> unit -> (string list, string) result`
- `resolve_declared_name : ?sw/net/clock:_ -> raw_name:string -> unit -> (string, string) result`
- `models_of_cascade_name : ?sw/net/clock:_ -> string -> (string list, string) result`
- `inspect_active` returns the full snapshot with profile metadata (`keeper_assignable`, `fallback_cascade`, `required_capability_profile`, etc.).

The snapshot already carries every field `catalog_entry` exposes; readers can be ported one-to-one.

### 2.4 Test fixture inventory

After the Pattern A sweep (PR #14616), ~30 test fixtures across 6 suites write per-profile `[X]\nmodels = [...]` TOML and rely on the materializer's flat key arm + legacy reader. They pass today because the materializer still emits the flat keys; under this RFC's Phase 4 they would all fail.

Affected suites:
- `test_cascade_catalog_runtime` (23 fixtures via the inline `flat_json_to_toml` helper)
- `test_cascade_toml_materialization` (~5 fixtures)
- `test_cascade_required_capability_profile` (~5 fixtures)
- `test_cascade_secondary_entry_parser` (~8 fixtures)
- `test_cascade_hierarchical_routing` (1 fixture uses `[X]\nmodels`; 2 already use `groups`)
- `test_dashboard_cascade` (~10 fixtures)

---

## 3. Design

### 3.1 Reader replacement map

| Legacy call | Replacement | Notes |
|---|---|---|
| `load_catalog ~config_path` | `Cascade_catalog_runtime.inspect_active ()` → extract `snapshot.profiles` | Snapshot carries the equivalent `catalog_entry` fields. Path arg dropped; resolver/runtime own the path. |
| `load_profile_weighted ~config_path ~name` | `Cascade_catalog_runtime.models_of_cascade_name name` plus `lookup_active_profile` for the full weighted entries | Returns `Result`; callers gain explicit error surfacing. |
| `load_profile ~config_path ~name` | `models_of_cascade_name` (drops weight metadata, same as legacy) | Direct substitute. |
| `is_deprecated_logical_profile_name` | Stays — it filters logical-route aliases that should *never* be catalog profiles regardless of source. | No-op rename / live as-is. |

### 3.2 Materializer arm removal

`profile_field_json ~field_name:"models"` (and `temperature`/`strategy`/`fallback_cascade`/... per-profile arms): once no reader consumes the flat JSON shape, the arms become dead emitters. Delete them; the per-profile `[X]` block becomes a parse error so operators discover the new schema requirement explicitly rather than silently being ignored.

### 3.3 Snapshot reentrancy

`Cascade_catalog_runtime` already caches the active snapshot keyed by `source_path` mtime, and `inspect_active` is reentrancy-safe (mutex-guarded `_cache`). Hot-path callers (`Keeper_config.default_cascade_name`, `keeper_turn_cascade_budget`, etc.) can call it freely; each call resolves to a cheap `Hashtbl.find_opt` after the first mtime check.

For very hot paths that pre-RFC read the cached-string, introduce `default_cascade_name : unit -> string` returning the live answer (or the spec-driven `Cascade_routes.first_alias_or_key Keeper_turn` if the snapshot is unavailable). Callers add `()`. The blast radius is 18 sites, all internal.

### 3.4 Test fixture migration

Two strategies:

1. **Per-profile → declarative tier-group**: each `[X]\nmodels = ["provider:auto"]` block becomes
   ```toml
   [tier.X]
   members = ["X-binding"]   # references a binding name

   [tier-group.X]
   tiers = ["X"]

   [routes.keeper_turn]      # if X was the keeper default
   target = "tier-group.X"
   ```
   Plus the matching `[providers.<provider>]` + `[<provider>.<model>]` binding blocks.

2. **`flat_json_to_toml` helper retrofit** (`test_cascade_catalog_runtime.ml`): widen the inline JSON→TOML transformer to emit the declarative shape instead of per-profile blocks. The fixture call sites stay unchanged; the helper now produces declarative TOML.

Strategy (2) is cheap for the 23-fixture catalog_runtime suite. Strategy (1) is required for the per-fixture-tailored tests where fixture content is itself the subject of assertion.

---

## 4. Phases

### Phase 1 — `Keeper_cascade_profile` reader migration (Task #29, target PR)

Replace the 3 sites in `lib/keeper/keeper_cascade_profile.ml` (`catalog_entries`, `catalog_names`, `catalog_names_result`) with `Cascade_catalog_runtime` queries. Add `Keeper_config.default_cascade_name : unit -> string` returning the live snapshot's first profile (with the existing static fallback for boot ordering). Update 18 callers to `()`.

Acceptance:
- All existing tests pass (Pattern A fixtures still emit flat JSON which the materializer keeps emitting — Phase 1 doesn't touch the materializer arm).
- `Cascade_catalog_runtime.resolve_declared_name ~raw_name:""` returns the same name as `Keeper_config.default_cascade_name ()` in test fixtures that install a catalog.
- Production behavior of `keeper_turn_cascade_budget`/`keeper_turn_up_create`/etc. now references the *live* default cascade name (`"big_three"` per current config), not the init-cached `"default"`.

### Phase 2 — Remaining lib callers migration (Task #30)

`lib/dashboard_cascade.ml`, `lib/cascade_catalog_validator.ml`, `lib/cascade/cascade_routes.ml`, `lib/cascade/cascade_catalog_runtime.ml` (internal callers — yes, the runtime itself calls the legacy loader in one spot), `lib/cascade/cascade_config.ml` (4 sites). Each ports to the snapshot reader.

Acceptance:
- `rg "Cascade_config_loader\.load_(catalog|profile_weighted|profile)\b" lib/` returns zero hits.
- All existing tests still pass (still Phase A test fixtures emit flat JSON).

### Phase 3 — Test fixture migration (Task #31)

Migrate fixtures suite-by-suite. Order by mechanical-ness:
- `test_cascade_catalog_runtime`: extend `flat_json_to_toml` to emit declarative TOML (strategy 2).
- `test_cascade_required_capability_profile`: hand-rewrite 5 fixtures (strategy 1).
- `test_cascade_secondary_entry_parser`: hand-rewrite 8 fixtures.
- `test_cascade_toml_materialization`, `test_cascade_hierarchical_routing`, `test_dashboard_cascade`: hand-rewrite specific fixtures.

Acceptance:
- All cascade-area suites pass on declarative-only fixtures.
- Materializer arm `<profile>_models` flat key emission is now unused at runtime; gating that with a CI-asserted "no flat key emission" test is acceptable scope creep.

### Phase 4 — Delete legacy API (Task #32)

Remove:
- `Cascade_config_loader.load_catalog` + `.mli` signature.
- `load_profile_weighted` + `.mli`.
- `load_profile` + `.mli`.
- `load_cascade_profile_flat_models` and `load_cascade_profile` (the per-profile bridge).
- `weighted_entry` type if no other reader consumes it.
- `catalog_entry` type — replaced by the snapshot's profile representation.
- The per-profile field arms in `Cascade_toml_materializer.profile_field_json` (`models`, `temperature`, `strategy`, ...) and the surrounding `profile_table_json_fields` if nothing else uses them.

Final acceptance:
- `rg "load_catalog\|load_profile" lib/` returns zero hits.
- `rg "_models" lib/cascade/` returns zero hits in the *materializer* path; only the declarative `[models.X]` namespace remains.
- `dune build` clean; all cascade tests pass; CI green.

---

## 5. Risks

### 5.1 Snapshot bootstrap ordering

`Keeper_config` module-init currently reads `Keeper_cascade_profile.cascade_name_for_use Keeper_turn` at load time. If we replace it with a function that consults `Cascade_catalog_runtime`, callers during very early boot (before catalog install) get the static fallback path. This matches today's behavior (init-cached `"default"` = static spec fallback), so no regression — but it does mean the *first* runtime caller after catalog install sees the new value, not the cached one. Document explicitly: callers that need bootstrap-stable values should pin them at the call site.

### 5.2 Per-profile-only operator configs

Audit each known operator setup (kidsnote, internal envs). If any operator has a per-profile `cascade.toml` they wrote by hand, Phase 4 breaks them. Mitigation: Phase 4 ships with a migration script (`scripts/cascade/migrate_flat_to_declarative.sh`) that converts per-profile blocks to the equivalent tier-group/binding triple, and a one-release deprecation window where the materializer arm logs a `WARN` on use.

### 5.3 Test suite migration churn

~30 fixtures across 6 suites. Phase 3 risks getting bogged down. Mitigation: do the mechanical `flat_json_to_toml` retrofit first (covers 23 fixtures), then attack remaining suites in priority order, each as its own PR.

### 5.4 Hidden flat-key consumers outside `lib/`

`rg` only scans the current source tree. Forks, downstream plugins, and operator scripts that read `cascade.json` directly would break. Mitigation: Phase 4 PR body includes a "downstream check" callout asking maintainers to grep their forks.

---

## 6. Acceptance criteria

Cumulative across phases:

1. `Keeper_config.default_cascade_name ()` returns the live snapshot's first profile (not the init-cached spec fallback) when a catalog is installed. Closes #14624.
2. `Cascade_config_loader.load_catalog` / `load_profile_weighted` / `load_profile` / `load_cascade_profile_flat_models` deleted. No lib reader of `<profile>_models` flat JSON keys remains.
3. `Cascade_toml_materializer` no longer emits `<profile>_models` keys. Per-profile `[X]\nmodels = [...]` TOML blocks parse-error explicitly.
4. All cascade-area test suites (8 suites, ~166 tests) green on declarative-only fixtures.
5. CI green; `dune build` clean; no new ocamlformat violations in changed files (existing pre-existing violations not reformatted per project policy).

---

## 7. Related documents

- RFC-0058 (declarative cascade config) — establishes the schema this RFC closes out
- Issue #14624 — root-cause tracker, closed by this RFC
- PR #14611, #14616, #14620, #14623 — the Phase 9.3 fallout sweep that surfaced the dependency
- `~/me/feedback_lint_string_classifier_is_workaround_not_fundamental.md` — methodological precedent for "remove the structural cause rather than guard the symptom"
