---
status: reference
---

# Environment Variable Contract

This document defines the operator-facing contract for environment variables in
`masc`.

The core rule is simple:

- Environment variables are a process boot contract.
- Accessor-shaped code such as `let foo () = Sys.getenv_opt ...` does not imply
  shell-level hot reload.
- A running process only observes new env values when the process itself calls
  `Unix.putenv`, when an in-process boot override store is consulted, or when
  the value is modeled as separate runtime parameter state such as
  `Runtime_params`.

Use this document together with [`TOML-RELOAD-MATRIX.md`](./TOML-RELOAD-MATRIX.md).

## Reload Classes

| Class | Meaning | Typical mechanism |
| --- | --- | --- |
| `boot_static` | Requires process restart | socket bind, config root resolution, startup seeding |
| `sweep_dynamic` | Applied on next supervisor sweep or periodic reconcile | running keeper declarative profile sync |
| `request_dynamic` | Applied on next request/turn/lookup | `runtime.toml` resolve path, some runtime getters |
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
| Runtime root and config root | `MASC_BASE_PATH`, `MASC_CONFIG_DIR`, `HOME` | `Config_dir_resolver` caches the resolved root for the life of the process |
| Server bind and socket topology | `MASC_HOST`, `MASC_HTTP_PORT`, `MASC_GRPC_PORT`, `MASC_GRPC_ENABLED`, `MASC_WS_ENABLED` | listeners and advertised base URLs are fixed during server startup |
| Backend/bootstrap wiring | `MASC_STARTUP_WATCHDOG_SEC` | boot-time watchdog setup; storage is filesystem-only by construction |
| Startup-only TOML seeding | every `MASC_KEEPER_*` value sourced from `runtime.toml` | TOML is loaded once and injected into the process env during boot |

Representative code paths:

- [`server_runtime_bootstrap.ml`](../lib/server/server_runtime_bootstrap.ml)
- [`config_dir_resolver.ml`](../lib/config_dir_resolver/config_dir_resolver.ml)
- [`server_bootstrap_http.ml`](../lib/server/server_bootstrap_http.ml)
- [`keeper_runtime_config.ml`](../lib/keeper_runtime/keeper_runtime_config.ml)
- [`keeper_tool_policy.ml`](../lib/keeper/keeper_tool_policy.ml)

### 2. Env-backed defaults that become runtime-dynamic through `Runtime_params`

These env values still enter the system as boot inputs, but the effective
runtime parameter authority is `Runtime_params`, not the parent shell env.

| Effective contract | Examples | Operator path |
| --- | --- | --- |
| `immediate_dynamic` | `keeper.keepalive_interval_sec`, `keeper.supervisor_sweep_sec`, `keeper.work_as_hb_enabled`, `keeper.smart_hb_enabled` | update via the typed `Runtime_params` dashboard endpoints |
| `request_dynamic` | keeper temperature/max_tokens and similar registered params | next `Runtime_params.get` call observes the override |

Representative code paths:

- [`runtime_params.ml`](../lib/runtime_params.ml)
- [`keeper_config.ml`](../lib/keeper/keeper_config.ml)
- [`server_routes_http_routes_activity.ml`](../lib/server/server_routes_http_routes_activity.ml)

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
  [`env_config_runtime.ml`](../lib/config/env_config_runtime.ml)
  are accessor-shaped, but listener lifecycles remain boot-static.
- `Config_dir_resolver` helpers read env accessors, but
  [`resolve()`](../lib/config_dir_resolver/config_dir_resolver.ml)
  caches the result, so root changes are boot-static.

### 4. Execute exec gates (`request_dynamic`, additive-only)

Flags introduced by the P1–P6 exec rework. Each is opt-in: the
default keeps the pre-Execute JSON shape and execution path, and
turning a flag on only adds new fields or new code branches. No
field is ever removed by these flags, so downstream consumers
never break by enabling them.

Operator rollout procedure and observer log interpretation: see
[`EXECUTE-RUNBOOK.md`](./EXECUTE-RUNBOOK.md).

Representative code paths:

- [`exec_buffer.ml`](../lib/core/exec_buffer.ml)
- [`exec_policy.ml`](../lib/exec_policy/exec_policy.ml) — Shell_command_gate policy integration

Because every flag here is `request_dynamic` on the Execute path
(read at tool-invocation time), operators can flip a flag without a
restart and the next `Execute` call picks it up.

### 5. WebSearch provider selection (`boot_static` seed, request-time read)

The WebSearch backend reads these values while handling each search request.
Values can be authored either as process env vars or in
`<resolved-config-root>/runtime.toml` under `[web_search]`. Runtime TOML values
are loaded into the process-local boot override store at startup, so
`runtime.toml` edits require a process restart. Changing the process env inside
the running process is still picked up on the next WebSearch call.

Precedence:

1. Process env var
2. `[web_search]` value from `runtime.toml`
3. Built-in default

| Variable | Default | Effect |
| --- | --- | --- |
| `MASC_SEARXNG_URL` | `http://localhost:8888` | Enables the self-hosted SearXNG provider and gives it first priority when present. Use `scripts/searxng-local.sh start` to run a Docker-backed local instance with JSON output enabled. |
| `MASC_WEB_SEARCH_PROVIDER` | `auto` | Pins one provider instead of auto order selection. |
| `MASC_WEB_SEARCH_PROVIDER_ORDER` | built-in order | Overrides provider order for auto mode. |
| `MASC_WEB_SEARCH_FALLBACKS` | built-in fallback order | Overrides fallback providers after the primary provider fails. |
| `MASC_WEB_SEARCH_TIMEOUT_SEC` | `15` | Per-provider request timeout. |
| `MASC_WEB_SEARCH_CACHE_TTL_SEC` | `900.0` | In-process WebSearch cache TTL. |
| `BRAVE_SEARCH_API_KEY` | `(none)` | Env-only credential; presence admits the `brave` and `brave_llm_context` providers. |
| `TAVILY_API_KEY` | `(none)` | Env-only credential; presence admits the `tavily` provider. |
| `EXA_API_KEY` | `(none)` | Env-only credential; presence admits the `exa` provider. |
| `BING_SEARCH_API_KEY` | `(none)` | Env-only credential; presence admits the `bing_api` provider. |
| `AZURE_BING_SEARCH_API_KEY` | `(none)` | Azure-issued alias with the same admission as `BING_SEARCH_API_KEY`. |
| `OLLAMA_API_KEY` | `(none)` | Env-only credential; presence admits the `ollama` provider. |

Web artifact corpus (RFC-0383): every truncation offload stores the full
extraction as a content-addressed blob in the `Tool_blob_store`
(`<base>/.masc/tool_blobs/<sha[0..1]>/<sha256>`) — the exact store
`keeper_artifact_read` resolves (#28820) — and appends one
`masc.web_artifact.v1` fact row (`sha256`, `source_url`, optional `title`,
`bytes`, `fetched_at`) to `<base>/.masc/artifacts/web-fetch/index.jsonl`.
The index is a projection — deleting it changes no behavior. Lane note: a
keeper re-reads a body with the sha carried by its `[TRUNCATED ...
full_text_sha256=<sha>]` marker; discovering shas by `Grep`-ing the index is
an agent/operator-lane path (keeper sandboxes do not expose `.masc` as a
file surface — keeper-lane cross-session discovery is tracked in #28820).
MASC never deletes blobs or index rows; retention is operator-managed
(#28759).

Equivalent `runtime.toml` keys:

```toml
[web_search]
searxng_url = "http://localhost:8888"
provider = "auto"
provider_order = "searxng,brave,tavily,exa,bing_api"
fallbacks = "tavily,exa"
timeout_sec = 15
cache_ttl_sec = 900.0
```

Representative code paths:

- [`tool_misc_web_search.ml`](../lib/tool_misc_web_search.ml)
- [`env_config_runtime.ml`](../lib/config/env_config_runtime.ml)
- [`keeper_runtime_config.ml`](../lib/keeper_runtime/keeper_runtime_config.ml)
- [`masc_network_defaults.ml`](../lib/config/masc_network_defaults.ml)

### 6. Test-only boot overrides

The following flags exist only to make OCaml test executables deterministic:

| Variable | Default test behavior | Opt-in behavior |
| --- | --- | --- |
| `MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE` | ignore inherited `MASC_CONFIG_DIR` captured from the parent shell | preserve an explicit config-root override for resolver coverage |

These are not operator-facing runtime controls and should not be used as
production launch knobs.

Representative code paths:

- [`workspace_utils_backend_setup.ml`](../lib/workspace/workspace_utils_backend_setup.ml)
- [`config_dir_resolver.ml`](../lib/config_dir_resolver/config_dir_resolver.ml)

## Rules for New Environment Variables

1. New env vars default to `boot_static`.
2. If operator live tuning is needed, add a `Runtime_params` entry instead of
   relying on shell env mutation.
3. Document the `reload_class` at the declaration site and in the relevant
   operator doc.
4. Do not use the phrase `runtime-readable` in operator-facing docs. Use one of
   the four reload classes instead.
