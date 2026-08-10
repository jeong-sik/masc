# OAS Architecture

## Layer overview

```
│  lib/  (agent_sdk)                          │
│  Layer 1: Agent Runtime                     │
│  Agent, Pipeline, Provider, Error, Tools    │
├─────────────────────────────────────────────┤
│  OCaml 5.x + Eio                            │
│  Structured concurrency, effect handlers    │
└─────────────────────────────────────────────┘
```

## Layer 1: Agent Runtime

Single-agent execution engine.

| Module | Responsibility |
|--------|---------------|
| `Agent` | Lifecycle: create, run, resume |
| `Pipeline` | Turn preparation, provider routing, extraction, tools, and state update |
| `Provider` | Multi-provider API dispatch (Anthropic, OpenAI, Ollama) |
| `Error` | 8-domain structured ADT errors |
| `Hooks` | BeforeTurn, AfterTurn, PreToolUse, PostToolUse hooks |
| `Tracing` | TRACER module type, Null/Fmt/OTel implementations |
| `Metrics` | Counter + histogram collection, OTLP JSON export |
| `Guardrails_async` | Caller-injected content validation |
| `Tool_set` | Tool registration, schema generation |

## Error model

```
sdk_error
├── Api of api_error          (provider API and transport failures)
├── Provider of provider_error (provider configuration, request, and parse failures)
├── Agent of agent_error      (stop reason, hook, guardrail, tripwire, or input request)
├── Mcp of mcp_error          (server, initialization, list, call, or HTTP failure)
├── Config of config_error    (missing, unsupported, invalid, or sensitive configuration)
├── Serialization of serialization_error
├── Io of io_error
├── Orchestration of orchestration_error
└── Internal of string
```

All error domains use record payloads for context. Pattern matching is exhaustive — adding a new domain causes compile errors at all handler sites.

## Concurrency model

Eio structured concurrency: every fiber runs within a `Switch.t`.
- Switch guarantees cleanup on exit (normal or exception)
- Parent switch cancellation propagates through the fiber tree
- Timeout/error containment depends on the combinator contract:
  - `Async_agent.race` is fail-fast; the first completion cancels
    remaining siblings.
  - `Async_agent.all` is all-settled; per-agent timeouts and ordinary
    exceptions are returned in that agent's result while sibling agents finish.
  - `Guardrails_async` keeps validator failures local to that validator result.
- No resource leaks by construction

```
Switch.run @@ fun sw ->
  Eio.Fiber.all [
    (fun () -> agent_1.run ~sw prompt);
    (fun () -> agent_2.run ~sw prompt);
  ]
(* Both fibers complete or cancel here — no orphans *)
```
