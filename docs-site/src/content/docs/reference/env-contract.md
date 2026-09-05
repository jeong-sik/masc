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
| `MASC_GRPC_PORT` · `MASC_GRPC_ENABLED` · `MASC_WS_ENABLED` | gRPC/WebSocket transports |
| `MASC_STARTUP_WATCHDOG_SEC` | Boot watchdog |

### Web search (read at request time)

`[web_search]` values may live in `runtime.toml` or the environment. Precedence: process env > `runtime.toml` > built-in default.

| Variable | Default | Effect |
|---|---|---|
| `MASC_SEARXNG_URL` | `http://localhost:8888` | Enables the self-hosted SearXNG provider at first priority |
| `MASC_WEB_SEARCH_PROVIDER` | `auto` | Pins one provider |
| `MASC_WEB_SEARCH_TIMEOUT_SEC` | `15` | Per-provider request timeout |
| `BRAVE_SEARCH_API_KEY` · `TAVILY_API_KEY` · `EXA_API_KEY` · `BING_SEARCH_API_KEY` | (none) | Admits the named search provider |

### Provider API keys

There is no fixed list: `[providers.<id>.credentials]` in `runtime.toml` (`type = "env"`, `key = "<name>"`) names the variable. The install and quickstart scripts write `.env.local` (mode 600).

## Rules for new environment variables

1. New vars default to `boot_static`.
2. Live tuning needs a `Runtime_params` entry, not shell mutation.
3. Document the `reload_class` at the declaration site and in the operator doc.
4. Do not write "runtime-readable" in operator docs; use one of the four classes.
