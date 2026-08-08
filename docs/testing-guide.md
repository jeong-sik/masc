# Zero-LLM Testing Guide

OAS supports testing agent logic without calling any LLM API.
This is the primary testing strategy for `agent_sdk` itself.

## How it works

`Agent.run` ultimately consumes pure OCaml data and effectful callbacks.
Replace provider-facing seams with functions that return fixed responses.

```ocaml
let mock_response =
  Ok
    {
      Types.id = "m";
      model = "m";
      stop_reason = EndTurn;
      content = [Text "task complete"];
      usage = None;
    }
```

## Mock patterns

### Fixed text response

```ocaml
let smart_mock ~sw:_ prompt =
  if String.length prompt > 100 then
    Ok { Types.id = "m"; model = "m"; stop_reason = EndTurn;
         content = [Text "summarized"]; usage = None }
  else
    Error (Error.Internal "prompt too short")
```

## What you can test without LLM

| Capability | How |
|-----------|-----|
| Tool-handling turn loop | Stub tool results and verify follow-up turns |
| Timeout behavior | Set short wall-clock timeouts and verify graceful exit |
| Provider error recovery | Return typed `sdk_error` values from mocks |
| Pipeline behavior | Assert stage-by-stage transformations stay deterministic |
| Explicit caller-selected context reducer | Feed large prompts and verify reducer output |
| Hook ordering | Capture side effects in test-local refs |

## Why this matters

- Tests run in <0.3s (no network, no API keys)
- Deterministic (no LLM variance)
- CI-friendly (no secrets needed)
- Type system guarantees mock = real (same runtime contracts)
