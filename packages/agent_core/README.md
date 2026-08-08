# agent-sdk

[![CI](https://github.com/jeong-sik/oas/actions/workflows/ci.yml/badge.svg)](https://github.com/jeong-sik/oas/actions/workflows/ci.yml)

> Personal project. No production SLA, no external support, no compatibility guarantees. The API surface changes on the author's schedule. Use at your own risk.
>
> 개인 프로젝트입니다. 프로덕션 SLA, 외부 지원, 호환성 보증 없음. 사용 시 자기 책임.

OCaml agent SDK on OCaml 5.x + Eio. Single-process, single-Eio-domain runtime. Talks to Anthropic Messages API and OpenAI-compatible chat endpoints (which covers many local servers, OpenRouter, and similar gateways), plus a local llama-server profile. See `lib/api_*.ml` for the actually wired endpoints.

- OCaml package: `agent_sdk` (in `lib/`)
- OCaml module: `Agent_sdk`
- Requires: OCaml >= 5.1, Dune >= 3.11
- Current version: source of truth is `lib/sdk_version.ml`

## Installation

```bash
opam pin add agent_sdk git+https://github.com/jeong-sik/oas.git#main --yes
```

For development (with test dependencies):

```bash
git clone https://github.com/jeong-sik/oas.git && cd oas

# Required fork pins (OCaml 5.4 compat)
source scripts/mcp-sdk-pin.sh
opam pin add bisect_ppx git+https://github.com/patricoferris/bisect_ppx.git#5.2 --no-action --yes
opam pin add mcp_protocol "git+${MCP_SDK_URL}#${MCP_SDK_SHA}" --no-action --yes

opam install . --deps-only --with-test --yes
scripts/dune-local.sh build @all
```

## Quickstart

```ocaml
open Agent_sdk

let () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  Eio.Switch.run @@ fun sw ->
  let provider_config =
    Llm_provider.Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"qwen3.5"
      ~base_url:"http://127.0.0.1:8085"
      ()
  in
  let agent =
    Agent.create ~net
      ~config:
        { (Types.default_config ~model:provider_config.model_id) with
          name = "hello";
          system_prompt = Some "You are a helpful assistant. Be concise.";
        }
      ~options:{ Agent.default_options with provider_config = Some provider_config }
      ~tools:[] ()
  in
  match Agent.run ~sw agent "What is 2 + 2?" with
  | Ok response ->
      List.iter
        (function Types.Text t -> print_endline t | _ -> ())
        response.content
  | Error e -> prerr_endline (Error.to_string e)
```

This pins a local OpenAI-compatible server on port 8085. OAS does not select a
provider when `provider_config` is absent. For Anthropic, supply the endpoint,
model, and credential explicitly:

```ocaml
match Sys.getenv_opt "ANTHROPIC_API_KEY" with
| None | Some "" -> Error "ANTHROPIC_API_KEY is required"
| Some api_key ->
    let provider_config =
      Llm_provider.Provider_config.make
        ~kind:Anthropic
        ~provider_id:"anthropic"
        ~model_id:"claude-sonnet-4-6"
        ~base_url:"https://api.anthropic.com"
        ~api_key
        ()
    in
    Ok
      (Agent.create ~net
         ~config:
           { (Types.default_config ~model:provider_config.model_id) with name = "hello" }
         ~options:{ Agent.default_options with provider_config = Some provider_config }
         ~tools:[] ())
```

See `examples/` for more: `basic_agent.ml`, `tool_use.ml`,
`async_agent_demo.ml`, `streaming.ml`, `review_agent.ml`,
`observable_agent.ml`, and `builder_patterns.ml`.
For tool concurrency rules see `docs/tool-concurrency.md`.

## Provider support

Agent execution has one provider carrier:
`Agent.options.provider_config : Llm_provider.Provider_config.t option`.
`Provider_config.kind` selects the wire format:

| Kind | Endpoint family |
|------|-----------------|
| `Anthropic` / `Kimi` | Anthropic Messages-compatible |
| `OpenAI_compat` | OpenAI Chat Completions-compatible |
| `Ollama` | Ollama native chat |
| `Gemini` | Gemini native |
| `Glm` | GLM native |
| `DashScope` | DashScope native |

Construct the exact value with `Llm_provider.Provider_config.make`, or resolve a
declared provider catalog row with `Provider_runtime_binding.find` followed by
`Provider_runtime_binding.to_provider_config`. The direct path carries the
credential. The catalog path preserves provider identity, endpoint, request
path, and declared capabilities; the application must resolve the binding's
declared auth source and attach its credential explicitly. A missing catalog
binding, missing credential, or absent agent provider is an explicit error;
OAS does not guess from a model id, URL, or environment.

## Architecture

OAS ships one opam library in this repository:

```
Layer 1: agent_sdk  (lib/)
            |  Single-agent runtime: turn loop, tool dispatch, hooks.
            |
            +-- lib/agent/         Agent lifecycle, turns, tools, handoff, builder
            +-- lib/pipeline/      6-stage turn pipeline
            +-- lib/protocol/      A2A, MCP, Agent Card, Agent Registry
            +-- lib/llm_provider/  Shared LLM types, HTTP client, streaming
            +-- lib/*.ml           Context, Hooks, Runtime, etc.
```

Anything outside this repository — multi-process coordination, repo-wide task queues, dashboards, persistent shared state — is the responsibility of an external coordinator, not of OAS. OAS deliberately knows nothing about any specific coordinator.

### Layer 1: Agent Runtime (`agent_sdk`)

| Module | Role |
|--------|------|
| `Types` | Domain types: message, role, stop_reason, content_block, SSE events |
| `Llm_provider.Provider_config` | Exact provider identity, wire kind, endpoint, credential, request path, and capability carrier |
| `Provider_runtime_binding` | Fail-closed conversion from a declared catalog binding to `Provider_config.t` |
| `Agent` | Multi-turn agent loop with automatic tool_use handling (abstract `Agent.t`) |
| `Tool` / `Tool_set` | Tool definition, JSON Schema generation, O(1) lookup |
| `Builder` | Fluent API for agent construction with `build_safe` validation |
| `Hooks` | Generic lifecycle callbacks; `PreToolUse` accepts exact caller-owned `Continue`, `Block`, or `ElicitToolApproval` decisions |
| `Context` | Cross-turn shared state (scoped key-value store, `Yojson.Safe.t` values) |
| `Error` / `Error_domain` | 2-level structured errors: 8 domain variants + Internal, poly-variant mapping |
| `Log` | Structured logging with level filtering and composable sinks |
| `Mcp` | MCP client (NDJSON-over-stdio, server lifecycle, paginated tool listing) |
| `Pipeline` | 6-stage turn pipeline; the Route stage dispatches through `Llm_provider.Complete` |
| `Contract` | Prompt/context composition: instruction layers, triggers, skills |
| `Plan` | Goal decomposition with dependency DAG and re-planning |

## Module stability tiers

Not all modules are equally stable. Use this to gauge risk when depending on a module.
The public facade modules below carry explicit `@stability` and `@since`
markers; unannotated modules are Internal by default.
For the current classification policy, see `docs/api-stability.md`.

**Stable** -- safe to depend on, breaking changes require a major version bump:

`Types`, `Error`, `Agent`, `Builder`, `Tool`, `Tool_set`, `Hooks`, `Provider`, `Raw_trace`, `Checkpoint`, `Checkpoint_store`, `Context`

**Evolving** -- API may change between minor versions:

`Streaming`, `Structured`, `Runtime`

CDAL proof artifacts are no longer exposed as public OCaml modules from OAS.
Use the versioned JSON schema catalog for downstream proof-bundle artifacts.

**Internal** -- implementation details with no compatibility promise:

`lib/agent/*` submodules, `lib/protocol/*`, `lib/llm_provider/*` backends, parser/transport helpers, and other implementation-specific support modules

## Tool definition

```ocaml
(* Simple handler *)
let calc_tool =
  Tool.create ~name:"calculator"
    ~description:"Evaluate a math expression"
    ~parameters:[{
      Types.name = "expression";
      description = "The math expression";
      param_type = String; required = true;
    }]
    (fun args ->
      let open Yojson.Safe.Util in
      match args |> member "expression" |> to_string_option with
      | Some expr ->
          Ok { Types.content = Printf.sprintf "Result: %s" expr; _meta = None }
      | None ->
          Error
            { Types.message = "missing expression"
            ; recoverable = false
            ; error_class = None
            })

(* Context-aware handler *)
let counter_tool =
  Tool.of_schema
    (Types.tool_schema_of_params
      ~name:"counter"
      ~description:"Increment and return counter"
      ~parameters:[]
      ())
    (Tool.requiring_context (fun ctx _input ->
      let n = match Context.get ctx "count" with
        | Some (`Int n) -> n + 1 | _ -> 1 in
      Context.set ctx "count" (`Int n);
      Ok { Types.content = string_of_int n; _meta = None }))
```

## Hooks and HITL

```ocaml
let my_hooks = { Hooks.empty with
  pre_tool_use = Some (function
    | Hooks.PreToolUse { tool_name; _ } ->
        Printf.printf "Calling: %s\n" tool_name;
        Hooks.Continue
    | _ -> Hooks.Continue);
}
```

OAS sends the caller-supplied `Tool_set` to the provider unchanged. A product
that needs tool exposure policy applies its own typed gate before constructing
the agent. A caller that has already settled an external-effect decision may
return `Hooks.Block reason` from `PreToolUse`, or `Hooks.ElicitToolApproval`
and configure `Builder.with_tool_approval` when the exact call needs caller
input. `Hooks.ElicitInput` is generic user input and cannot authorize a tool;
the approval callback must settle synchronously. OAS does not install a timer
or durable pause at that boundary and does not own approval,
judging, risk levels, or HITL orchestration.

## Build and test

```bash
scripts/dune-local.sh build <target>
make test

# Full CI parity only when explicitly needed
scripts/dune-local.sh build @all
scripts/dune-local.sh runtest

# Coverage report
make coverage

# Integration tests (requires local LLM server)
LLAMA_LIVE_TEST=1 dune exec ./test/test_local_llm.exe
LLAMA_LIVE_TEST=1 dune exec ./test/test_streaming_e2e.exe

# Run examples
dune exec examples/basic_agent.exe
dune exec examples/review_agent.exe -- jeong-sik/oas 123
```

## Constraints and trade-offs

- HTTP response body limit: 10MB.
- SSE streaming uses real-time event callbacks. OAS performs one provider
  attempt; any later caller-owned attempt starts outside the completed stream.
- The tool-use loop continues until the provider returns a terminal response or the caller cancels the fiber.
- Runs on a single Eio domain. No multi-core parallelism.
- Prompt caching tracks `cache_creation_input_tokens` and `cache_read_input_tokens` in both streaming and non-streaming modes (since v0.4.0).

## Scope limitations

OAS is a single-process, single-Eio-domain agent runtime. The following concerns are explicitly out of scope and belong to a downstream consumer or a separate library.

| What | Owner | Why not here |
|------|-------|-------------|
| Worktree / filesystem coordination | External coordinator | Multi-process file locking and git worktree lifecycle are coordinator concerns, not SDK concerns. |
| MCP transport implementation | `mcp-protocol-sdk` | OAS consumes `mcp_protocol` as an opam dependency. Transport details (NDJSON framing, stdio management) live there. |
| Operator dashboard / visibility | External coordinator | Real-time agent status, workspace views, and supervisor dashboards belong to a layer that aggregates across processes. |
| Repo-level task and shared-state management | External coordinator | Task queues, claim semantics, and shared workspace state are coordination-plane concepts that span multiple agents and sessions. |
| Workflow scheduling / SaaS isolation | Embedding application | Cron triggers, tenant isolation, and multi-user access control are problems for the system that embeds OAS. |
| Long-term persistence / vector storage | Embedding application | Session state, memory backends, and embedding indexes are injected via callbacks, not owned by the SDK. |

If you find yourself pulling one of these responsibilities into `agent_sdk`, that is a signal the change belongs in a different repository. OAS does not name any specific downstream coordinator on purpose: anyone wiring OAS into a coordination layer should be free to make their own architectural choices.

## Versioning

The authoritative version string lives in `lib/sdk_version.ml` (mirrored in `dune-project` and `agent_sdk.opam`). Do not trust a number written into this README — it will drift.

We follow semver intent within the 0.x series:
- **0.x.0**: May contain breaking changes with migration guide in `CHANGELOG.md`.
- **0.x.y** (y > 0): Additive features and bug fixes only.

These are intent-level commitments on a personal project, not contractual guarantees.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and code style.
