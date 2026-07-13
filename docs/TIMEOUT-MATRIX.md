# Timeout Matrix (SSOT)

Status: Phase 1 — observability + module stub. Migration of call sites is tracked in #9639.

## Layer model

MASC timeout policy is progress-first. Provider streams and tool invocations are
separate timeout domains: `stream_idle_timeout_sec` watches provider transport
silence, while tool deadlines stay in the tool layer. No OAS/keeper stream
timeout knob should be read as tool timeout policy. `MASC_KEEPER_TURN_TIMEOUT_SEC`
is now a retry/admission budget between provider attempts, not the hard
execution deadline for an active turn.

| Layer | Role | Typical cap | Source of truth |
|-------|------|-------------|-----------------|
| `Tool` | per-tool HTTP / shell invocation | 10–60 s | `Env_config_runtime.*`, `lib/tool_local_runtime_http.ml` |
| `MCP tools/call` | outer per-tool dispatcher cap | 60 s default; board writes 90 s default | `MASC_TOOL_TIMEOUT_DEFAULT_SEC`, `MASC_TOOL_TIMEOUT_BOARD_SEC`, `Mcp_server_eio_call_tool.tool_timeout_sec_opt` |
| `Oas_bridge` | single OAS `Agent.run` / `Model.call` | no cumulative cap on the keeper `run_named` path; provider stream idle and attempt liveness apply; Agent-level no-progress idle is opt-in only; tool timeouts are outside this layer | `MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC`, `MASC_KEEPER_EXECUTION_IDLE_TIMEOUT_SEC`, `Keeper_attempt_liveness` |
| `Keeper_turn` | one keeper turn (may issue many OAS calls) | 600 s default retry/admission budget; not a hard execution kill | `MASC_KEEPER_TURN_TIMEOUT_SEC`, `Keeper_turn_runtime_budget*` |
| `Keeper_cycle` | full keeper lifecycle | N×turn | cycle supervisor |
| `Shutdown` | graceful shutdown board flush | 2 s | `bin/main_eio.ml` |

## Cooperative-cancel overshoot

OCaml 5 / Eio cancellation is cooperative. `Eio.Time.with_timeout_exn` sets a
deadline, but the fiber only observes the cancel at the next cancellation
point. A fiber blocked in:

- a native HTTP bulk read
- a non-yielding tight loop
- a syscall with no Eio-aware wrapper
- a third-party C stub that ignores cancel

will continue executing past the deadline, producing a wall time greater than
the configured budget. Example from production (#9662):

> `keeper_llm_bridge` reported `timed out after 596.6s (budget=573s)` — ~24 s
> overshoot.

`Timeout_policy.overshoot_warn` emits a structured warn whenever the
observed wall time exceeds the cap by more than `slack_s` (default 5 s). The
warning preserves the same fields (`layer`, `origin`, `budget`, `actual`,
`excess`, `slack`) so the condition is grep-able and can feed a metric.

## Operator outcome

Provider timeout failures are not global shutdown signals. A single
`provider_timeout` is scoped to the provider attempt whose stream idle or
attempt-liveness budget was exceeded. Tool invocation timeouts are reported by
the tool layer instead. The turn ledger and runtime-trust snapshot must surface
provider-owned timeout evidence as provider timeout detail. Turn-owned
retry/admission budget exhaustion may still surface as `turn_timeout`, but
active provider-stream progress must not become
`terminal_reason.code = "turn_wall_clock_timeout"` merely because cumulative
wall time crossed 600 s. The runtime-trust snapshot mirrors the latest action,
and the runtime surface marks the keeper as needing attention with
`next_human_action = "inspect_runtime_blocker"` when the keeper is not paused.
Provider timeouts remain typed failure observations with provider/runtime
detail. They may cause lane-local retry or restart after backoff, but no
consecutive strike count promotes them into pause, Dead, or a fleet-wide gate.
Retired timeout-budget wire labels are not emitted into operator state.

For parallel OAS work, distinguish all-settled fanout from fail-fast race:
`Async_agent.all` contains per-agent timeout/error results while siblings
finish; `Async_agent.race` and tripwire guardrails intentionally cancel
siblings when the first branch completes or trips.

## Design references

- Go `context.Context.Deadline()` + `select` — propagated deadline + polled
  cancellation.
- gRPC deadline propagation — deadline attaches to the call; inner services
  clamp their own budget to `min(own_default, inherited_deadline - now)`.
- Rust `tokio::time::timeout` — forced drop; lifetime ends at the deadline
  regardless of task state.
- Envoy/Istio route timeout + retry budget — outer hard-cap separates from
  per-retry soft budgets.

MASC currently uses the *cooperative* variant (like Go/gRPC) rather than
forced-drop (Rust Tokio). The observability step is a prerequisite for any
future migration to forced-drop or marker-based kill.

## Migration plan

Phase 1 (this PR): module stub + keeper_llm_bridge overshoot warn.

Phase 2 (follow-ups): migrate each site in the table below to construct a
`Timeout_policy.Deadline.t` at entry and surface its `layer`/`origin` in
logs. Candidates:

| Site | Current cap | Owning issue |
|------|-------------|--------------|
| MCP `tools/call` default | 60 s via `MASC_TOOL_TIMEOUT_DEFAULT_SEC`; board write tools use 90 s via `MASC_TOOL_TIMEOUT_BOARD_SEC` | #10569 |
| `keeper_llm_bridge` | 300 s default inside 600 s keeper turn | #9639, #9662 |
| `Process_eio` `git status --porcelain` | 15 s | #9632 |
| `Process_eio` `git rev-parse` | 5 s | #9765, #9775 |
| Docker sandbox `git fetch origin` | 30 s | #9587 |
| Dashboard cache compute | 16 s | #9643 |
| `operator_snapshot` refresh | 30–36 s | #9734 |
| `a2a_tools` call | 300 s | — |
| `tool_local_runtime_http` | 10 s | — |
| `admission_queue.wait_timeout_sec` | unused | #9639 note |

## Non-goals

- This policy module does NOT reimplement OAS retry/budget semantics — OAS
  owns its own `max_turns` and progress/idle liveness (see `feedback_no-lifecycle-
  invasion-from-masc.md`). MASC-side retry/admission budgets decide whether a
  new provider attempt may start; they are not a cumulative hard cap on an
  active stream.
- This module does NOT perform forced cancellation. It only makes cooperative
  overshoot observable.
