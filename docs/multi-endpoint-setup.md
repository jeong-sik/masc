# Multi-Endpoint LLM Setup

OAS supports multiple explicitly declared endpoints with round-robin load
balancing across declarations that pass their protocol-specific probes.

## Quick Start

```ocaml
let endpoints =
  [ Discovery.endpoint
      ~protocol:Discovery.Openai_compatible
      ~capabilities:my_catalog_entry.capabilities
      "http://127.0.0.1:8085"
  ; Discovery.endpoint
      ~protocol:Discovery.Openai_compatible
      ~capabilities:another_catalog_entry.capabilities
      "http://127.0.0.1:8086"
  ]
```

## Running Multiple llama-server Instances

```bash
# 3x 9B models on different ports
llama-server -m qwen3.5-9b.gguf --port 8085 --n-gpu-layers 99 &
llama-server -m qwen3.5-9b.gguf --port 8086 --n-gpu-layers 99 &
llama-server -m qwen3.5-9b.gguf --port 8087 --n-gpu-layers 99 &

# Or mixed models
llama-server -m qwen3.5-35b.gguf --port 8085 &
llama-server -m qwen3.5-9b.gguf  --port 8086 &
llama-server -m qwen3.5-9b.gguf  --port 8087 &
```

## Explicit Discovery

OAS does not scan ports or infer a provider protocol from a URL. The embedding
application declares every endpoint's closed protocol variant and catalog
capabilities, then asks the registry to probe those declarations.

A typical embedding application would call this at server startup. Standalone OAS users call it explicitly:

```ocaml
Eio.Switch.run @@ fun sw ->
let net = Eio.Stdenv.net env in
match Provider_registry.refresh_llama_endpoints ~sw ~net ~endpoints with
| Ok statuses ->
  (* Healthy declarations now form the active round-robin snapshot. Probe
     failures remain visible in each status. *)
  statuses
| Error Provider_registry.No_endpoints_declared ->
  failwith "no endpoint declarations"
| Error (Provider_registry.No_healthy_endpoints statuses) ->
  report_probe_failures statuses
```

## Load Balancing

`Provider_registry.next_llama_endpoint ()` returns `Some endpoint` in
round-robin order using lock-free `Atomic.fetch_and_add`. The value retains its
protocol and capability declarations; the registry never lowers it back to a
bare URL. It returns `None` until a typed refresh succeeds. Safe for concurrent
Eio fibers.

## API Reference

| Function | Description |
|----------|-------------|
| `refresh_llama_endpoints ~sw ~net ~endpoints` | Probe typed declarations and update the active list, or return an explicit error |
| `next_llama_endpoint ()` | Get the next endpoint as an option (round-robin) |
| `active_llama_endpoints ()` | Snapshot of current endpoint list |

## Health Probes

OpenAI-compatible declarations use these probes:

- `GET /health` (or endpoint root) — reachability
- `GET /v1/models` — loaded model inventory
- `GET /props` — total slots and context
- `GET /slots` — per-slot busy/idle status

Ollama-native declarations use `GET /api/tags` for model inventory. OAS does
not call `/api/show` and does not inspect chat templates.

An OpenAI-compatible declaration is active only when it is reachable and its
required model inventory matches the declared schema. An Ollama-native
declaration is active only when `/api/tags` returns a valid model inventory.

## Failure Semantics

An empty declaration list returns `No_endpoints_declared`. If every declaration
is unhealthy, `No_healthy_endpoints statuses` retains the previous active
snapshot and exposes the endpoint-local failures. One failed endpoint never
stops another endpoint's probe lane.
