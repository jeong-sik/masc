# Telemetry Pipeline Integration Test Design

> Scope: Phase 5.2 — `test_telemetry_pipeline.ml`
> Date: 2026-05-10
> Worktree: `.worktrees/telemetry-design`

## 1. Purpose

Verify that `Pipeline.run_turn` emits `Telemetry_event.t` variants into
`Telemetry_bus` when executing against a mocked LLM provider that produces
chunks.  This is an end-to-end test of the OAS signal emission layer (Phase 1)
without involving a real network or MASC consumer.

## 2. Approach

### 2.1 Principle: Mock at the provider boundary

We mock the provider *backend*, not the HTTP layer.  The test wires a
`Custom_registered` provider config pointing to a module that implements the
`Provider.Backend.S` interface (or the subset used by `Complete.complete_*`).
The mock returns a fixed stream of SSE chunks including:

- `role=assistant` delta
- First content chunk (`first_chunk` flag or delta content)
- Thinking block markers (if exercising `Thinking_complete`)
- Final usage block with `prompt_eval_count` / `prompt_eval_duration`

This keeps the test deterministic and fast (no Eio network fibers).

### 2.2 Telemetry assertions

After `Pipeline.run_turn` returns, we:

1. Drain `Telemetry_bus`.
2. Assert the event list contains at least one `Streaming_first_chunk`.
3. Assert the event list contains `Prefill_complete` with the expected token
   count from the mocked usage block.
4. Optionally assert `Thinking_complete` if the mock stream includes thinking
   markers.
5. Assert no `Timeout` event (the mock responds instantly).

### 2.3 Avoided pitfalls

| Pitfall | Mitigation |
|---------|------------|
| Real HTTP timeouts | Mock backend returns `Eio.Stream` directly |
| Sandbox path issues (SCA test lesson) | No filesystem or shell dependency |
| Dune sandbox isolation | Test runs entirely in-memory; `(deps)` unnecessary |
| Flaky timing assertions | Mock timestamps injected; no `Sys.time ()` checks |

## 3. Module Dependencies

```
test_telemetry_pipeline.ml
  ├── Agent_sdk
  ├── Llm_provider.Telemetry_event
  ├── Telemetry_bus
  ├── Pipeline
  ├── Types
  ├── Provider
  └── Alcotest
```

The test links against `agent_sdk`, `llm_provider`, and `alcotest`.

## 4. Mock Provider Specification

```ocaml
module Mock_backend : Provider.Backend.S = struct
  type config = unit

  let complete_streaming ~sw:_ ~config:_ ~prompt:_ ~params:_ ~handler:_ =
    (* Emit synthetic chunks through handler *)
    ...
  ;;

  let complete_sync ~config:_ ~prompt:_ ~params:_ =
    Error (`Msg "mock: sync not implemented")
  ;;
end
```

Chunk sequence:
1. `delta = { role = Some "assistant" }` — sets role.
2. `delta = { content = Some "Hello" }` — first content chunk; triggers
   `Streaming_first_chunk`.
3. `delta = { reasoning = Some "Thinking..." }` — thinking start marker.
4. `delta = { reasoning = Some "" }` — thinking end; triggers
   `Thinking_complete`.
5. `delta = { content = Some " world" }` — second content chunk; triggers
   `Streaming_chunk_n`.
6. `usage = { prompt_tokens = 10; completion_tokens = 2; total_tokens = 12 }`
   — final block; triggers `Prefill_complete`.

## 5. Test Case Breakdown

### 5.1 `test_pipeline_emits_first_chunk`

- Action: Run `Pipeline.run_turn` with mock provider.
- Expected: `Telemetry_bus.drain` contains `Streaming_first_chunk`.
- Rejects: Silent failure where no telemetry events are produced.

### 5.2 `test_pipeline_emits_prefill`

- Action: Same as above.
- Expected: `Telemetry_bus.drain` contains `Prefill_complete` with
  `prompt_eval_tokens = 10`.

### 5.3 `test_pipeline_no_timeout_on_fast_mock`

- Action: Same as above.
- Expected: `Telemetry_bus.drain` contains zero `Timeout` events.

### 5.4 `test_pipeline_emits_thinking`

- Action: Run with mock provider configured to emit thinking markers.
- Expected: `Telemetry_bus.drain` contains `Thinking_complete`.

## 6. Dune Stanza

```dune
(test
 (name test_telemetry_pipeline)
 (modules test_telemetry_pipeline)
 (libraries agent_sdk llm_provider alcotest eio_main))
```

No `(deps)` or `(action)` needed — the test is hermetic.

## 7. Open Questions / Risks

1. **Provider.Backend.S surface**: The exact interface used by `Pipeline.run_turn`
   for provider dispatch needs to be verified.  If it uses `Complete.complete_*`
   directly rather than a backend module, the mock point shifts to
   `llm_provider/complete.ml`.
2. **Pipeline.run_turn arity**: This function takes `~agent_config`, `~context`,
   `~provider`, and `~hooks`.  Constructing a minimal valid `agent_config` and
   `context` inside a test may require helper factories.
3. **Telemetry_bus singleton vs local**: `Pipeline.run_turn` must be
   instrumented to accept an optional `?telemetry_bus` argument, or the test
   must rely on a module-level singleton.  The former is preferred for test
   isolation.

## 8. Verification Criteria

- [ ] `dune exec` passes all 4 cases.
- [ ] `dune runtest` passes in sandbox (no path assumptions).
- [ ] Test completes in < 100 ms (mock, no network).
