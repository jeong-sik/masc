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
| Runtime root and config root | `MASC_BASE_PATH`, `MASC_CONFIG_DIR`, `HOME` | `Config_dir_resolver` caches the resolved root for the life of the process (`<base-path>/.masc/` owns all runtime state) |
| Server bind and socket topology | `MASC_HOST`, `MASC_HTTP_PORT`, `MASC_GRPC_PORT`, `MASC_GRPC_ENABLED`, `MASC_WS_ENABLED` | listeners and advertised base URLs are fixed during server startup |
| Backend/bootstrap wiring | `MASC_STARTUP_WATCHDOG_SEC`, `MASC_JSONL_RETENTION_DAYS` | boot-time watchdog setup and unified dated JSONL retention (default `30` days; `[maintenance] jsonl_retention_days` in `runtime.toml`) |
| Sandbox DNS | `[sandbox] microvm_dns` | the nameserver a microVM guest is booted with (`runtime.toml` only; one IPv4 or IPv6 address) |
| Startup-only TOML seeding | every `MASC_KEEPER_*` value sourced from `runtime.toml` | TOML is loaded into the process-local boot override store. A registry row marked `Toml_only` reads only that store and never the process environment. `MASC_KEEPER_AUTONOMOUS_ENABLED`, `MASC_OTEL_ENABLED`, `MASC_SEARXNG_URL` and `MASC_KEEPER_HEARTBEAT_INTERVAL_SEC` are `Toml_and_env`: an explicit process env value takes precedence |

To write a `runtime.toml` key from a script, for example before a workspace's
first start, run `masc config set KEY=VALUE --base-path <path>`. `KEY` is a
dotted key the settings registry names, such as `autonomous.enabled`. A
workspace that has no `runtime.toml` is seeded the way server start seeds it,
then the key is edited in place with comments kept. A key the registry does not
name, or a value that is not the kind the key holds, is refused and nothing is
written. What a value means is checked when the server starts.

Floating-point values reach boot readers at their parsed precision. This also
applies to existing files: a provider-call deadline that is shorter than an
explicit first-event or stream-idle timeout is refused when Keeper runtime
settings freeze, even if older six-digit rounding made the pair appear equal.
Check these timeout relationships before upgrading. `config set` checks each
setting's type and range; it does not check that relationship. The settings
view retains the existing short display when it round-trips; otherwise it shows
enough digits to distinguish the parsed float. Application status compares the
actual parsed numbers.

Representative code paths:

- [`server_runtime_bootstrap.ml`](../lib/server/server_runtime_bootstrap.ml)
- [`config_dir_resolver.ml`](../lib/config_dir_resolver/config_dir_resolver.ml)
- [`server_bootstrap_http.ml`](../lib/server/server_bootstrap_http.ml)
- [`keeper_runtime_config.ml`](../lib/keeper_runtime/keeper_runtime_config.ml)
- [`keeper_tool_policy.ml`](../lib/keeper/keeper_tool_policy.ml)

### 2. Env-backed defaults that become runtime-dynamic through `Runtime_params`

These settings enter the system as boot inputs: a `runtime.toml` key, plus the
process env for the few settings the registry marks `Toml_and_env`. The
effective runtime parameter authority is `Runtime_params`, not the parent shell
env.

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

- Transport boolean flags in
  [`env_config_runtime.ml`](../lib/config/env_config_runtime.ml)
  are accessor-shaped, but listener lifecycles remain boot-static.
- `Config_dir_resolver` helpers read env accessors, but
  [`resolve()`](../lib/config_dir_resolver/config_dir_resolver.ml)
  caches the result, so root changes are boot-static.

#### Keeper auxiliary JSONL rotation

The `[metrics]` keys `max_bytes` and `max_rotated` configure the auxiliary
JSONL writer used for decision logs, response feedback and runtime manifests.
The typed
[`runtime setting registry`](../lib/config/keeper_runtime_setting_registry.ml)
owns their defaults, bounds and operator-facing descriptions.

At the next size-triggered rotation, `max_rotated = 0` discards old versions;
reducing the count removes excess numbered backups. `max_bytes = 0` disables
both rotation and that cleanup. TOML changes require restart to reload the
boot override store; these readers observe the loaded value on each append.

Date-sharded turn and heartbeat metrics under
`keepers/<name>/metrics/YYYY-MM/DD.jsonl` use `Dated_jsonl.append` separately.
These two settings do not limit that store's size or retention.

#### Date-sharded Keeper metrics

`metrics.store_max_bytes` sets a
separate per-Keeper byte target for date-sharded turn and heartbeat metrics.
The default `0` preserves every record. A positive value is captured when
the store opens, so changing this setting requires restart.

Both producers use the same writer and store mutex. File segments use half
the target (at least one byte), leaving room for a preceding segment alongside
the current one. When the next record would exceed that segment size, the
writer rotates the current day file and appends the record, then removes the
oldest completed files until the store fits. Retention removes whole files;
it does not promise an exact number of historical records. The latest record
always lands, even if that single record exceeds the byte target, and cleanup
remains best effort on filesystem errors. Auxiliary logs, turn records,
provider-input snapshots and other Keepers' histories have separate stores.

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
They are authored in `<resolved-config-root>/runtime.toml` under `[web_search]`.
Runtime TOML values are loaded into the process-local boot override store at
startup, so `runtime.toml` edits require a process restart. Only
`MASC_SEARXNG_URL` can also come from a process env var, which wins over
`runtime.toml`. API keys are env-only.

`masc web-search-setup` prints which provider has its credential and what to
export for the rest, and writes the `[web_search]` keys below. It never writes an
API key: those stay in the environment of the process that starts the server.

Precedence:

1. `[web_search]` value from `runtime.toml` (for `MASC_SEARXNG_URL`, a process env var comes first)
2. Built-in default

| Key or variable | Default | Effect |
| --- | --- | --- |
| `MASC_SEARXNG_URL` | `http://127.0.0.1:8888` | Enables the self-hosted SearXNG provider and gives it first priority when present. Use `scripts/searxng-local.sh start` from a checkout, or `masc prerequisite-actions searxng` from an installed binary, to run a Docker-backed local instance with JSON output enabled. The second prints the one action that fits the container: `searxng_docker_run` when there is none, `searxng_docker_start_existing` when one is stopped (`--execute <id>`); a running, paused, restarting or unusable container has none, and `dependency_readiness` says which it is. `searxng_docker_run` writes `<base-path>/.masc/searxng/settings.yml` unless a file is there, bind-mounts `<base-path>/.masc/searxng:/etc/searxng`, pulls an image fixed by tag and digest, and starts the container `masc-searxng` with `--restart unless-stopped`, published on `127.0.0.1:8888` only. `searxng_docker_start_existing` starts that name as Docker created it and writes nothing, so a container the script made keeps the address and directory the script gave it. Neither sets this variable or `web_search.searxng_url`. The default is `http://127.0.0.1:8888`, not `localhost`: a program listening on `[::1]:8888` answers `localhost` and the container does not. An instance that only listens on `[::1]` needs an explicit URL. |
| `[web_search] provider` | `auto` | Pins one provider instead of auto order selection. |
| `[web_search] provider_order` | built-in order | Sets the provider order for auto mode. |
| `[web_search] fallbacks` | built-in fallback order | Sets the fallback providers after the primary provider fails. |
| `[web_search] timeout_sec` | `15` | Per-provider request timeout. |
| `[web_search] cache_ttl_sec` | `900.0` | In-process WebSearch cache TTL. |
| `BRAVE_SEARCH_API_KEY` | `(none)` | Env-only credential; presence admits the `brave` and `brave_llm_context` providers. |
| `TAVILY_API_KEY` | `(none)` | Env-only credential; presence admits the `tavily` provider. |
| `EXA_API_KEY` | `(none)` | Env-only credential; presence admits the `exa` provider. |
| `BING_SEARCH_API_KEY` | `(none)` | Env-only credential; presence admits the `bing_api` provider. |
| `AZURE_BING_SEARCH_API_KEY` | `(none)` | Azure-issued alias with the same admission as `BING_SEARCH_API_KEY`. |
| `OLLAMA_API_KEY` | `(none)` | Env-only credential; presence admits the `ollama` provider. |
| `ZAI_API_KEY` | `(none)` | Env-only credential; the `zai` provider (z.ai Web Search MCP, GLM Coding Plan) reads it when named in `provider`, `provider_order` or `fallbacks`. It is not in the default order. A `zai` search is three requests, each under `timeout_sec`. The `glm-coding` model provider reads the same variable. |

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
searxng_url = "http://127.0.0.1:8888"
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
