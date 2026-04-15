# Environment Variable Contract

This document defines the operator-facing contract for environment variables in
`masc-mcp`.

The core rule is simple:

- Environment variables are a process boot contract.
- Accessor-shaped code such as `let foo () = Sys.getenv_opt ...` does not imply
  shell-level hot reload.
- A running process only observes new env values when the process itself calls
  `Unix.putenv`, when an in-process boot override store is consulted, or when
  the value is modeled as a separate runtime control plane such as
  `Runtime_params`.

Use this document together with
[`BOOT-ENV-STATE-INVENTORY.md`](./BOOT-ENV-STATE-INVENTORY.md) and
[`TOML-RELOAD-MATRIX.md`](./TOML-RELOAD-MATRIX.md).

## Reload Classes

| Class | Meaning | Typical mechanism |
| --- | --- | --- |
| `boot_static` | Requires process restart | socket bind, config root resolution, startup seeding |
| `sweep_dynamic` | Applied on next supervisor sweep or periodic reconcile | running keeper declarative profile sync |
| `request_dynamic` | Applied on next request/turn/lookup | `cascade.json` resolve path, some runtime getters |
| `immediate_dynamic` | Applied immediately inside the running process | `Runtime_params.set`, in-process override mutation |

## Default Policy

Every environment variable is treated as `boot_static` unless one of the
following is true:

1. The process mutates its own effective config inside the process, such as
   `Unix.putenv` or a boot override store.
2. The effective value is mediated through `Runtime_params`.
3. The consumer explicitly re-reads the source on the next request/turn and the
   surrounding subsystem is not already structurally fixed at boot.

The important operational distinction is:

- `runtime-readable` is an implementation detail.
- `reload_class` is the supported contract.

## Environment Variable Matrix

### 1. Boot-static environment inputs

These values decide process structure, roots, or startup-loaded policy and
should be treated as restart-required.

| Scope | Examples | Why |
| --- | --- | --- |
| Runtime root and config roots | `MASC_BASE_PATH`, `MASC_CONFIG_DIR`, `MASC_PERSONAS_DIR`, `HOME` | `Config_dir_resolver` caches the resolved root for the life of the process |
| Server bind and socket topology | `MASC_HOST`, `MASC_HTTP_PORT`, `MASC_GRPC_PORT`, `MASC_WS_PORT`, `MASC_GRPC_ENABLED`, `MASC_WS_ENABLED`, `MASC_WEBRTC_ENABLED` | listeners and advertised base URLs are fixed during server startup |
| Backend/bootstrap wiring | `MASC_STORAGE_TYPE`, `MASC_POSTGRES_URL`, `MASC_PG_POOL_SIZE`, `MASC_STARTUP_WATCHDOG_SEC` | boot-time backend wiring and watchdog setup |
| Startup-only TOML seeding | every `MASC_KEEPER_*` value sourced from `keeper_runtime.toml` | TOML is loaded once and injected into the process env during boot |
| Startup-loaded policy | tool policy related env plus `tool_policy.toml`-driven behavior | presets are loaded once at startup |

Representative code paths:

- [`server_runtime_bootstrap.ml`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/server/server_runtime_bootstrap.ml)
- [`config_dir_resolver.ml`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/config_dir_resolver.ml)
- [`server_bootstrap_http.ml`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/server/server_bootstrap_http.ml)
- [`keeper_runtime_config.ml`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/keeper/keeper_runtime_config.ml)
- [`keeper_tool_policy.ml`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/keeper/keeper_tool_policy.ml)

### 2. Env-backed defaults that become runtime-dynamic through `Runtime_params`

These env values still enter the system as boot inputs, but the effective
operator control plane is `Runtime_params`, not the parent shell env.

| Effective contract | Examples | Operator path |
| --- | --- | --- |
| `immediate_dynamic` | `keeper.keepalive_interval_sec`, `keeper.supervisor_sweep_sec`, `keeper.work_as_hb_enabled`, `keeper.smart_hb_enabled` | update via governance/dashboard APIs backed by `Runtime_params` |
| `request_dynamic` | keeper temperature/max_tokens and similar registered params | next `Runtime_params.get` call observes the override |

Representative code paths:

- [`runtime_params.ml`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/runtime_params.ml)
- [`governance_registry.ml`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/governance_registry.ml)
- [`keeper_config.ml`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/keeper/keeper_config.ml)
- [`server_routes_http_routes_activity.ml`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/server/server_routes_http_routes_activity.ml)

### 3. Accessor-shaped env readers with limited live effect

Some accessors are functions and therefore can re-read the process env.
Operationally, they should still be treated conservatively unless their
consumer is known to act on every request/turn.

| Pattern | Contract |
| --- | --- |
| Top-level `let foo = ...` | `boot_static` startup snapshot |
| `let foo () = ...` but consumer already allocated sockets/pools/fibers | still `boot_static` |
| `let foo () = ...` and consumer reads per request/turn | `request_dynamic` at most |

Examples:

- Transport feature flags in
  [`env_config_runtime.ml`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/config/env_config_runtime.ml)
  are accessor-shaped, but listener lifecycles remain boot-static.
- `Config_dir_resolver` helpers read env accessors, but
  [`resolve()`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/config_dir_resolver.ml#L321)
  caches the result, so root changes are boot-static.

## Rules for New Environment Variables

1. New env vars default to `boot_static`.
2. If operator live tuning is needed, add a `Runtime_params` entry instead of
   relying on shell env mutation.
3. Document the `reload_class` at the declaration site and in the relevant
   operator doc.
4. Do not use the phrase `runtime-readable` in operator-facing docs. Use one of
   the four reload classes instead.
