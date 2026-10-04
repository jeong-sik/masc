---
status: reference
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
| `maintenance_dynamic` | reconciled by independent configuration maintenance at startup, cadence, and owned cleanup |
| `request_dynamic` | applied on next request/turn/model resolve |

## Matrix

| File | Purpose | Load point | Reload trigger | Reload class | Notes |
| --- | --- | --- | --- | --- | --- |
| `<base_path>/.masc/config/runtime.toml` | startup env seeding for `MASC_KEEPER_*` and WebSearch knobs | server bootstrap before env-backed consumers initialize | none | `boot_static` | values are recorded in a process-local boot override store; edits require restart |
| `<resolved-config-root>/keepers/*.toml` | declarative keeper profile defaults | keeper create/up, explicit keeper operations, supervisor reconcile | next supervisor sweep or next keeper create/up | `sweep_dynamic` | running keepers re-sync declarative fields; no standalone file watcher |
| `<resolved-config-root>/lane-addons/*.toml` | declarative observer installations | independent Lane configuration Pulse | startup, existing maintenance cadence, and owned worker cleanup | `maintenance_dynamic` | malformed declarations preserve their applied installations; complete removal detaches the owned worker and preserves history |
| `<resolved-config-root>/runtime.toml` | runtime catalog source + optional `[fusion]` policy | model resolve path in agent core/MASC; `masc_fusion` handler reloads `[fusion]` per request | next resolve / next turn / next `masc_fusion` request | `request_dynamic` | invalid TOML blocks runtime or fusion policy load; `runtime.json` is retired |
| `<resolved-config-root>/candle.toml` | explicit Candle payout policy and portrait accessory prices | each Candle request (`Candle_config.load`) | next request | `request_dynamic` | no file means off; enabling requires the complete [payout policy](guides/candle-payout-policy.md), including nonempty grade amounts and matching criteria, explicit sharing/tie/deduction rounding policies and half_life; optional `shop.prices_milli` entries use canonical Item ids, and omitted prices stay Unpriced; empty, incomplete, unreadable, malformed, unknown-key or overflowing policies disable Candle with a reason without stopping the server |

## Current Behavior by File

### `runtime.toml`

- Loaded once at boot from
  [`Keeper_runtime_config.load_and_apply`](../lib/keeper_runtime/keeper_runtime_config.ml)
- Invoked during bootstrap in
  [`server_runtime_bootstrap.ml`](../lib/server/server_runtime_bootstrap.ml)
- Contract documented in
  [`keeper_runtime_config.mli`](../lib/keeper_runtime/keeper_runtime_config.mli)

Operational meaning:

- This file is a startup default injector, not a live runtime tuning plane.
- If live tuning is needed, the correct target is `Runtime_params`.

### `keepers/*.toml`

- Parsed by
  [`Keeper_types_profile.load_keeper_toml`](../lib/keeper/keeper_types_profile.ml)
- Resolved through
  [`Config_dir_resolver.keeper_toml_path_opt`](../lib/config_dir_resolver/config_dir_resolver.ml)
- Reconciled for running keepers by
  [`ensure_keeper_meta`](../lib/keeper/keeper_runtime.ml)
  inside the supervisor sweep
  ([`keeper_runtime.ml`](../lib/keeper/keeper_runtime.ml))

Operational meaning:

- Declarative fields are not instant.
- They are applied on the next sweep for running keepers, or on the next
  `keeper_up`/create path for inactive keepers.

### `lane-addons/*.toml`

- Resolved through `Config_dir_resolver.resolve_for_base_path`, with the existing
  `MASC_CONFIG_DIR` override, and read by
  [`Lane_addon_config`](../lib/lane_addon/lane_addon_config.mli).
- [`Lane_addon_runtime.start_configuration_service`](../lib/lane_addon/lane_addon_runtime.mli)
  uses the existing maintenance cadence on an independent Pulse. It does not
  join a Keeper turn or supervisor sweep.
- Package manifest paths and snapshot-file paths resolve from the installation
  declaration's directory. Desired and applied revisions remain separate from
  observation phase and source coverage.
- Read errors do not authorize deletion. A readable but malformed file remains
  an explicit issue; absence from a complete inventory removes its installation.
- See the [installation guide and supported example](guides/lane-addon-toml.md)
  for updates, removal, and the boundary with subsequent composition features.

### `runtime.toml`

- TOML parsing lives in
  [`Runtime_toml`](../lib/runtime/runtime_toml.ml) (`parse_file` for the path,
  `parse_string` for text).
- Parsed TOML is materialized into the typed `Runtime_schema.config` by
  [`Runtime.materialize_runtime_config_text`](../lib/runtime/runtime.ml); the
  file path goes through `Runtime.load_list`.
- A lane's ordered candidate runtime ids are read through
  [`Runtime_lane.ordered_candidates`](../lib/runtime/runtime_lane.ml).
- The materialized config is held in memory (`Runtime.loaded_state_ref`).
  It is replaced at boot and when a write commits through
  `Runtime.save_config_text` (dashboard raw save, keeper assignment).
  A hand edit to the file takes effect at the next restart.

Operational meaning:

- If `runtime.toml` exists, it is the authoring SSOT and invalid edits fail
  closed instead of falling back to stale JSON.
- Path selection is still tied to cached config-root resolution.
- Runtime and lane catalog changes apply at restart or through a committed
  write; a plain file edit does not update the next resolve/turn.
- `[fusion]` is also read from this file by `Fusion_config_loader.load` at
  `masc_fusion` handler time. Fusion edits therefore take effect on the next
  `masc_fusion` request, including `staged_judge_group_size`, and invalid
  `[fusion]` config fails that request closed.
- `max_concurrent_panels` and `max_concurrent_judges` are retired. They never
  controlled execution and must be removed from authored TOML; configured
  model identities define the exact Fusion fan-out set.

## Rules for New TOML Files

1. Name the file after its reload contract when possible.
2. If a TOML file only seeds env at startup, document it as `boot_static`.
3. If a TOML file is meant to affect running keepers, attach it to an explicit
   sweep/reconcile path.
4. Avoid the term `hot reload` unless the code has a concrete reload trigger.
