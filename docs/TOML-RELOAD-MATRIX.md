---
status: reference
last_verified: 2026-06-26
code_refs:
  - scripts/check-doc-truth.sh
  - config/
  - lib/fusion/
---

# TOML Reload Matrix

This document separates TOML-backed configuration by load point and reload
contract.

The key distinction is:

- `startup-loaded TOML` is not hot-reloaded just because it lives in a config
  file.
- `running keeper declarative TOML` can be reconciled on the next supervisor
  sweep.

## Reload Classes

| Class | Meaning |
| --- | --- |
| `boot_static` | requires process restart |
| `sweep_dynamic` | applied on next supervisor sweep or explicit keeper reconfigure |
| `request_dynamic` | applied on next request/turn/model resolve |

## Matrix

| File | Purpose | Load point | Reload trigger | Reload class | Notes |
| --- | --- | --- | --- | --- | --- |
| `<base_path>/.masc/config/runtime.toml` | startup env seeding for `MASC_KEEPER_*` and WebSearch knobs | server bootstrap before env-backed consumers initialize | none | `boot_static` | values are recorded in a process-local boot override store; edits require restart |
| ~~`<resolved-config-root>/tool_policy.toml`~~ | ~~keeper tool group policy~~ | ~~deleted~~ | — | — | Loader (`keeper_tool_policy_config.ml`) removed. Tool access is descriptor/registry-driven. |
| `<resolved-config-root>/keepers/*.toml` | declarative keeper profile defaults | keeper create/up, explicit keeper operations, supervisor reconcile | next supervisor sweep or next keeper create/up | `sweep_dynamic` | running keepers re-sync declarative fields; no standalone file watcher |
| `<resolved-config-root>/runtime.toml` | runtime catalog source + optional `[fusion]` policy | model resolve path in OAS/MASC; `masc_fusion` handler reloads `[fusion]` per request | next resolve / next turn / next `masc_fusion` request | `request_dynamic` | invalid TOML blocks runtime or fusion policy load; `runtime.json` is retired |

## Current Behavior by File

### `runtime.toml`

- Loaded once at boot from
  [`Keeper_runtime_config.load_and_apply`](../lib/keeper/keeper_runtime_config.ml)
- Invoked during bootstrap in
  [`server_runtime_bootstrap.ml`](../lib/server/server_runtime_bootstrap.ml)
- Contract documented in
  [`keeper_runtime_config.mli`](../lib/keeper/keeper_runtime_config.mli)

Operational meaning:

- This file is a startup default injector, not a live runtime tuning plane.
- If live tuning is needed, the correct target is `Runtime_params`.

### `tool_policy.toml` (retired)

- **Deleted**: `keeper_tool_policy_config.ml` and its TOML loader were removed.
  Tool access is now descriptor/registry-driven with denylist filtering only.
- The `config/tool_policy.toml` seed file is no longer checked in or read at boot.

### `keepers/*.toml`

- Parsed by
  [`Keeper_types_profile.load_keeper_toml`](../lib/keeper/keeper_types_profile.ml)
- Resolved through
  [`Config_dir_resolver.keeper_toml_path_opt`](../lib/config_dir_resolver.ml)
- Reconciled for running keepers by
  [`ensure_keeper_meta`](../lib/keeper/keeper_runtime.ml)
  inside the supervisor sweep
  ([`keeper_runtime.ml`](../lib/keeper/keeper_runtime.ml))

Operational meaning:

- Declarative fields are not instant.
- They are applied on the next sweep for running keepers, or on the next
  `keeper_up`/create path for inactive keepers.

### `runtime.toml`

- TOML source resolution/materialization lives in
  [`Runtime_toml_materializer`](../lib/runtime/runtime_toml_materializer.ml)
- Resolved via
  [`Runtime_runtime.models_of_runtime_id`](../lib/runtime/runtime_runtime.ml)
- The code renders TOML to an in-memory JSON-shaped view and caches by
  source-path mtime
  ([`runtime_runtime.ml`](../lib/runtime/runtime_runtime.ml))

Operational meaning:

- If `runtime.toml` exists, it is the authoring SSOT and invalid edits fail
  closed instead of falling back to stale JSON.
- Path selection is still tied to cached config-root resolution.
- Content changes are observed on the next resolve/turn, not by a dedicated
  watcher.
- `[fusion]` is also read from this file by `Fusion_config_loader.load` at
  `masc_fusion` handler time. Fusion edits therefore take effect on the next
  `masc_fusion` request, including `max_concurrent_judges` and
  `staged_judge_group_size`, and invalid `[fusion]` config fails that request
  closed.

## Rules for New TOML Files

1. Name the file after its reload contract when possible.
2. If a TOML file only seeds env at startup, document it as `boot_static`.
3. If a TOML file is meant to affect running keepers, attach it to an explicit
   sweep/reconcile path.
4. Avoid the term `hot reload` unless the code has a concrete reload trigger.
