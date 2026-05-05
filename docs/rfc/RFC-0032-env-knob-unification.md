# RFC-0032 — Environment Knob Unification

- **Status**: Draft
- **Author**: yousleepwhen (vincent)
- **Created**: 2026-05-05
- **Audit reference**: `docs/audit-responses/2026-05-05-integrated-improvement-design.md` §4-3, Phase 3 #15
- **Related**: RFC-0030 (`masc create` CLI), RFC-0031 (3-tier disclosure),
  `lib/env_config_core.ml`, `.github/workflows/ci.yml` (env knob catalog drift gate)

## 1. Problem

`rg "MASC_[A-Z_]+" lib scripts` returns **1662 raw mentions**. Some
of those are duplicate references to the same knob; the unique-knob
count is somewhere in the low hundreds (precise count requires a
cleanup tool, see §4.1). The audit estimated 443; the truth is bigger.

Three concrete defects:

1. **Naming drift.** Examples:
   `MASC_KEEPER_AUTOBOOT_MAX` vs `MASC_KEEPER_AUTOBOT_MAX` (typo'd
   variant lives on as a deprecated alias in
   `keeper_turn_slot.ml:36`). Multiply across hundreds of knobs and
   the deprecated-alias list is a source of confusion.
2. **No discoverability.** Operators read `keeper_turn_slot.ml` to
   find that `MASC_KEEPER_AUTOBOOT_MAX` exists; there is no `masc
   env list` and no schema dump.
3. **Layer coupling.** `MASC_CLIENT_CAPACITY` (env) and
   `cli_max_concurrent` (TOML field) are two layers for the same
   knob, with the env taking precedence. The relationship is
   documented as a comment in `cascade_client_capacity.ml:216` —
   correct but undiscoverable from outside that file.

The audit framed this as "443 → 50 통합 JSON" but that conflates two
distinct problems: (a) catalog the knobs (b) consolidate the runtime
layer. JSON-as-config is one possible (a) solution but doesn't address
(b) by itself.

This RFC separates the two and ships them in order.

## 2. Goal

- **2.1 Env catalog**: a single declarative source-of-truth listing
  every MASC_* knob with type, tier (per RFC-0031), default, valid
  range, deprecation status, and one-line description.
- **2.2 Runtime layer consolidation**: lookups go through
  `Env_config_core` (already exists) — every reach-around
  `Sys.getenv_opt "MASC_..."` in lib gets replaced with a typed
  catalog query.
- **2.3 Catalog drift gate**: CI fails the build when a new
  `MASC_*` reference appears in code without a corresponding catalog
  entry.

The audit's "통합 JSON config" idea is deferred — JSON-as-runtime-source
trades one ergonomic for another. The catalog-as-truth approach lets
operators keep using env vars (the today's normal interface) while
gaining the missing introspection.

## 3. Non-goals

- Replacing env vars with a JSON / TOML / YAML config as the runtime
  source. Env vars remain the source; the catalog describes them.
- Removing the `MASC_KEEPER_AUTOBOOT_MAX` ↔ `MASC_KEEPER_AUTOBOT_MAX`
  alias (or any other documented deprecated alias). Aliases stay
  until a documented deprecation cycle runs (RFC-0030's cleanup
  surface, post-CLI introduction).
- Rewriting the dashboard or operator UX to show the catalog. The
  catalog is for tooling + CI; operator UX is RFC-0031's lane.
- Migrating `.env` files. Operator scripts keep working; the catalog
  describes what the env var means, not how it's set.

## 4. Design

### 4.1 Catalog format

`config/env-knobs.toml` (SSOT):

```toml
[knob.MASC_KEEPER_AUTOBOOT_MAX]
tier = "advanced"
type = "int"
default = 32
min = 1
max = "max_int"
description = "Global turn slot cap across autonomous + reactive pools."
deprecated_aliases = ["MASC_KEEPER_AUTOBOT_MAX"]
owner_module = "lib/keeper/keeper_turn_slot.ml"

[knob.MASC_CLIENT_CAPACITY]
tier = "advanced"
type = "string"
format = "url=max,url=max,..."
description = "Per-URL client concurrency override; precedence over `cli_max_concurrent` TOML field."
related_field = "cli_max_concurrent"
owner_module = "lib/cascade/cascade_client_capacity.ml"
```

The `owner_module` field is the gate: each knob has exactly one
module that *consumes* it. Multiple modules referencing the same
knob is allowed (e.g. test harness reads it for setup), but only the
owner_module's read is the canonical lookup.

### 4.2 Catalog loader

```
val Env_catalog.load : unit -> catalog
val Env_catalog.lookup : catalog -> string -> knob option
val Env_catalog.validate_value : knob -> string -> Result.t
```

Loaded once at startup, immutable. The existing `Env_config_core`
module gains a thin wrapper:

```
val Env_config_core.get_int_typed
  : catalog:catalog -> name:string -> int

val Env_config_core.get_string_typed
  : catalog:catalog -> name:string -> string option
```

`get_int_typed` reads the env, validates against the catalog's
`type=int min=N max=M`, and returns the value (or the default on
miss). All `Sys.getenv_opt "MASC_..."` reach-arounds in `lib/`
migrate to this surface.

### 4.3 Drift gate

CI step (extending the existing `cascade-drift-gate` and
`env-knob-catalog-drift-gate` from `.github/workflows/ci.yml`):

```bash
# .github/workflows/ci.yml additions:
- name: env-knob-catalog-completeness
  run: |
    rg -oN '\bMASC_[A-Z][A-Z0-9_]+\b' lib/ | sort -u > /tmp/code_knobs.txt
    yq -r '.knob | keys[]' config/env-knobs.toml | sort -u > /tmp/catalog_knobs.txt
    diff /tmp/code_knobs.txt /tmp/catalog_knobs.txt
```

Drift = non-zero diff. The CI step fails with a list of missing
catalog entries (or extra catalog entries with no code reference).

The existing CI gate (`env-knob-catalog drift`, recently fixed in
#13064 and #13074) is the foundation; this RFC extends it from "the
catalog format is parsable" to "the catalog covers all uses".

### 4.4 Phased migration

Migration is per-module, not per-knob. Each `lib/<module>` PR:

1. Adds catalog entries for every knob referenced in that module.
2. Migrates the module's `Sys.getenv_opt` to `Env_config_core.*_typed`.
3. CI verifies completeness for the module's knobs.

Order of migration (by impact, low → high):

1. `lib/cascade/` — well-isolated, ~30 knobs.
2. `lib/keeper/` — hot path; ~50 knobs. Migrate per-keeper-submodule.
3. `lib/dashboard/` — ~20 knobs.
4. `lib/server/`, `lib/oas*/`, `lib/coord/` — remainder.

Each module migration is one PR. Total PR count: ~10–15.

## 5. Tests

- `test_catalog_loads_from_fixture`: round-trip TOML → catalog →
  lookup.
- `test_catalog_validate_int_range`: assert out-of-range values are
  rejected by `validate_value`.
- `test_catalog_deprecated_alias_resolves`: `MASC_KEEPER_AUTOBOT_MAX`
  resolves to the same knob entry as `MASC_KEEPER_AUTOBOOT_MAX`.
- `test_drift_gate_detects_missing_entry`: synthetic code change adds
  a `MASC_NEW_KNOB` reference; assert the drift gate would fail.
- `test_env_config_core_typed_int_default`: env unset → returns
  catalog default.
- `test_env_config_core_typed_int_clamp`: env value above `max` →
  clamps to max with a warning log entry.

## 6. Performance

Catalog load is one-time at startup (TOML parse of ~200-knob file is
sub-100ms). Lookups during runtime are `Hashtbl.find` from a
prefilled table; sub-microsecond. No hot-path regression.

## 7. Migration

The phasing in §4.4 means each PR is small. Open questions in §8
gate which PR ships first.

Existing `.env` files, operator scripts, and CI workflows that set
`MASC_*` keep working unchanged.

Deprecated aliases (e.g. `MASC_KEEPER_AUTOBOT_MAX`) are catalog
entries with `deprecated = true` + `successor = "..."`. The catalog
loader logs a warning when a deprecated alias is used. No removal in
this RFC.

## 8. Open questions

- **Should the catalog be hand-edited TOML or generated from
  attributes?** Tempting to use OCaml ppx attributes on the
  consumer-side `let` bindings, generating the catalog at build
  time. Held off — the catalog has fields (description, owner)
  that don't fit naturally as ppx attributes, and hand-edited
  TOML is reviewable per knob.
- **Should the drift gate run on every PR or nightly?** Per-PR;
  catalog drift is exactly the kind of thing that bit-rots if not
  enforced. The cost (rg + diff) is sub-second.
- **Should non-`MASC_*` env vars (e.g. `OPENAI_API_KEY`,
  `RUNPOD_API_TOKEN`) be in the catalog?** No — those are external
  third-party knobs without our naming control. The catalog covers
  knobs we own.
- **What about per-keeper / per-cascade env knobs that have a name
  template?** e.g. `MASC_KEEPER_<NAME>_FOO`. Held off — these are
  rare today. If they grow, the catalog gains a `template` field.

## 9. Decision log

- Catalog as TOML, not JSON — chosen for parity with existing config
  files. Cost: TOML doesn't have native list-of-table for the keys,
  but the per-knob nested-table form is fine.
- Phased per-module migration over big-bang — chosen because the
  alternative (one PR replacing all `Sys.getenv_opt` calls at once)
  would be unreviewable and would block all parallel work for the
  duration.
- No JSON-as-runtime-config — chosen against the audit's "443 → 50
  JSON" framing. Env vars are how operators interact today; the
  problem is *missing introspection*, not *wrong format*. The catalog
  fixes the right problem.
- Deprecated aliases preserved — chosen because removing
  `MASC_KEEPER_AUTOBOT_MAX` (typo'd alias) requires coordinating with
  every operator's `.env` file. RFC-0030 CLI provides the migration
  path; this RFC sets up the catalog that makes the deprecation
  visible.
