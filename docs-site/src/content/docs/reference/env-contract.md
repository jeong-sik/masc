---
title: Environment Contract
description: Which environment variables MASC reads, and when each takes effect.
---

Environment variables are a process boot contract. A running process does not observe new shell values; a changed value needs a restart. The single source of truth for persistent settings is `.masc/config/*.toml`. The original contract lives at `docs/ENV-CONTRACT.md` in the repository.

## Four reload classes

| Class | Meaning |
|---|---|
| `boot_static` | Restart required: socket binds, config roots, startup-loaded policy |
| `sweep_dynamic` | Applied on the next supervisor sweep, e.g. keeper profile sync |
| `request_dynamic` | Applied on the next request/turn, e.g. the `runtime.toml` resolve path |
| `immediate_dynamic` | Applied immediately, e.g. `Runtime_params` updates |

Default policy: every environment variable is `boot_static`. Live tuning goes through a `Runtime_params` entry, not a shell variable.

## Representative variables

### Boot-static

| Variable | Role |
|---|---|
| `MASC_BASE_PATH` | The root under which the `.masc/` workspace lives |
| `MASC_CONFIG_DIR` | Selects a different config root |
| `MASC_HOST` | Server bind address |
| `MASC_HTTP_PORT` | HTTP and MCP port |
| `MASC_LOG_LEVEL` | Log level (`debug`, `info`, `warn`, `error`) |
| `MASC_GRPC_PORT` · `MASC_GRPC_ENABLED` · `MASC_WS_ENABLED` | gRPC/WebSocket transports |
| `MASC_STARTUP_WATCHDOG_SEC` | Boot watchdog |
| `MASC_JSONL_RETENTION_DAYS` | Dated JSONL retention window in days (default `30`; overrides `[maintenance] jsonl_retention_days`) |

### Web search (read at request time)

`[web_search]` values live in `runtime.toml`: `provider` (default `auto`, pins one provider), `provider_order`, `fallbacks`, `timeout_sec` (default `15`, per-provider request timeout) and `cache_ttl_sec`. Only `MASC_SEARXNG_URL` can also come from the environment, and it wins over `runtime.toml`.

| Variable | Default | Effect |
|---|---|---|
| `MASC_SEARXNG_URL` | `http://127.0.0.1:8888` | Enables the self-hosted SearXNG provider at first priority |
| `ZAI_API_KEY` · `BRAVE_SEARCH_API_KEY` · `TAVILY_API_KEY` · `EXA_API_KEY` · `BING_SEARCH_API_KEY` · `AZURE_BING_SEARCH_API_KEY` · `OLLAMA_API_KEY` | (none) | Admits the named search provider |

### Provider API keys

There is no fixed list: `[providers.<id>.credentials]` in `runtime.toml` (`type = "env"`, `key = "<name>"`) names the variable, and the server reads it from the environment it was started in. Every keyed HTTP provider must declare a `[providers.<id>.credentials]` block in `runtime.toml`; omitting it is rejected with `credential_undeclared`. On a source checkout `quickstart.sh` writes `.env.local` (mode 600) and `start-masc.sh` loads it; a binary install has neither, so export the variable yourself.

## Rules for new environment variables

1. New vars default to `boot_static`.
2. Live tuning needs a `Runtime_params` entry, not shell mutation.
3. Document the `reload_class` at the declaration site and in the operator doc.
4. Do not write "runtime-readable" in operator docs; use one of the four classes.
