---
status: reference
last_verified: 2026-04-17
code_refs:
  - scripts/check-doc-truth.sh
  - config/
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
| `<base_path>/.masc/config/keeper_runtime.toml` | startup env seeding for `MASC_KEEPER_*` knobs | server bootstrap before `Env_config_keeper` consumers initialize | none | `boot_static` | values are recorded in a process-local boot override store; edits require restart |
| `<resolved-config-root>/tool_policy.toml` | keeper tool preset/group policy | server bootstrap via `init_policy_config` | none | `boot_static` | presets are stored in process memory once loaded |
| `<resolved-config-root>/keepers/*.toml` | declarative keeper profile defaults | keeper create/up, explicit keeper operations, supervisor reconcile | next supervisor sweep or next keeper create/up | `sweep_dynamic` | running keepers re-sync declarative fields; no standalone file watcher |
| `<resolved-config-root>/cascade.json` | model cascade order and per-cascade inference settings | model resolve path in OAS/MASC | next resolve / next turn | `request_dynamic` | OAS side uses mtime-based cache for JSON reloads |

## Current Behavior by File

### `keeper_runtime.toml`

- Loaded once at boot from
  [`Keeper_runtime_config.load_and_apply`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/keeper/keeper_runtime_config.ml#L148)
- Invoked during bootstrap in
  [`server_runtime_bootstrap.ml`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/server/server_runtime_bootstrap.ml#L188)
- Contract documented in
  [`keeper_runtime_config.mli`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/keeper/keeper_runtime_config.mli#L1)

Operational meaning:

- This file is a startup default injector, not a live runtime tuning plane.
- If live tuning is needed, the correct target is `Runtime_params`.

### `tool_policy.toml`

- Loaded once by
  [`Keeper_tool_policy.init_policy_config`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/keeper/keeper_tool_policy.ml#L57)
- Resolved from the active config root by
  [`keeper_tool_policy_config.ml`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/keeper/keeper_tool_policy_config.ml#L203)

Operational meaning:

- Editing this file changes policy for the next process boot.
- There is no in-process policy reload path today.

### `keepers/*.toml`

- Parsed by
  [`Keeper_types_profile.load_keeper_toml`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/keeper/keeper_types_profile.ml#L335)
- Resolved through
  [`Config_dir_resolver.keeper_toml_path_opt`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/config_dir_resolver.ml#L374)
- Reconciled for running keepers by
  [`ensure_keeper_meta`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/keeper/keeper_runtime.ml#L56)
  inside the supervisor sweep
  ([`keeper_runtime.ml`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/keeper/keeper_runtime.ml#L381))

Operational meaning:

- Declarative fields are not instant.
- They are applied on the next sweep for running keepers, or on the next
  `keeper_up`/create path for inactive keepers.

### `cascade.json`

- Resolved via
  [`Oas_model_resolve.models_of_cascade_name`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/oas_model_resolve.ml#L280)
- The code explicitly delegates JSON caching/reload to OAS and documents an
  mtime-based cache
  ([`oas_model_resolve.ml`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/oas_model_resolve.ml#L274))

Operational meaning:

- Path selection is still tied to cached config-root resolution.
- Content changes are observed on the next resolve/turn, not by a dedicated
  watcher.

## Rules for New TOML Files

1. Name the file after its reload contract when possible.
2. If a TOML file only seeds env at startup, document it as `boot_static`.
3. If a TOML file is meant to affect running keepers, attach it to an explicit
   sweep/reconcile path.
4. Avoid the term `hot reload` unless the code has a concrete reload trigger.
