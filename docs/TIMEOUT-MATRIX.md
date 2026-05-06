# Timeout Matrix (SSOT)

Status: Phase 1 — observability + module stub. Migration of call sites is tracked in #9639.

## Layer model

MASC-MCP timeouts nest innermost-first. Every inner layer's wall cap MUST be
`<=` its enclosing layer's cap. An inner "hard cap" that exceeds the outer cap
is effectively advisory.

| Layer | Role | Typical cap | Source of truth |
|-------|------|-------------|-----------------|
| `Tool` | per-tool HTTP / shell invocation | 10–60 s | `Env_config_runtime.*`, `lib/tool_local_runtime_http.ml` |
| `MCP tools/call` | outer per-tool dispatcher cap | 60 s default; board writes 90 s default | `MASC_TOOL_TIMEOUT_DEFAULT_SEC`, `MASC_TOOL_TIMEOUT_BOARD_SEC`, `Mcp_server_eio_call_tool.tool_timeout_sec_opt` |
| `Oas_bridge` | single OAS `Agent.run` / `Model.call` | 300 s default; provider attempt caps may be lower | `Env_config_keeper.oas_timeout_sec*`, `Oas_worker_named.effective_provider_attempt_timeout_s` |
| `Keeper_turn` | one keeper turn (may issue many OAS calls) | 600 s default/hard ceiling | `MASC_KEEPER_TURN_TIMEOUT_SEC` |
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

Timeout budget failures are not global shutdown signals. A single
`oas_timeout_budget` is scoped to the keeper turn that exhausted its OAS
budget. The turn ledger and runtime-trust snapshot must surface
`terminal_reason.code = "oas_timeout_budget"` with
`terminal_reason.next_action = "inspect_timeout_budget"`. The runtime-trust
snapshot mirrors that as `latest_next_action`, and the runtime surface marks
the keeper as needing attention with
`next_human_action = "inspect_timeout_budget"` when the keeper is not paused.
Paused timeout-budget cases keep the paused workflow
(`attention_reason = "paused_blocked"`,
`next_human_action = "inspect_runtime_blocker"`) while still exposing
`runtime_blocker_class = "oas_timeout_budget"`. Repeated consecutive budget
strikes are promoted by the keepalive loop to
`Oas_timeout_budget_loop`, which the supervisor auto-pauses instead of
restart-looping.

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

MASC-MCP currently uses the *cooperative* variant (like Go/gRPC) rather than
forced-drop (Rust Tokio). The observability step is a prerequisite for any
future migration to forced-drop or sentinel-based kill.

## Migration plan

Phase 1 (this PR): module stub + keeper_llm_bridge overshoot warn.

Phase 2 (follow-ups): migrate each site in the table below to construct a
`Timeout_policy.Deadline.t` at entry and surface its `layer`/`origin` in
logs. Candidates:

| Site | Current cap | Owning issue |
|------|-------------|--------------|
| MCP `tools/call` default | 60 s via `MASC_TOOL_TIMEOUT_DEFAULT_SEC`; board write tools use 90 s via `MASC_TOOL_TIMEOUT_BOARD_SEC` | #10569 |
| `keeper_llm_bridge` | 300 s default inside 600 s keeper turn | #9639, #9662 |
| Governance `compute_judgments` | 60 s | #9629 |
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
  owns its own `max_turns` and `max_duration` (see `feedback_no-lifecycle-
  invasion-from-masc.md`). The MASC-side deadline is the outer hard cap;
  OAS-side budgets are clamped within it by the caller, not mutated here.
- This module does NOT perform forced cancellation. It only makes cooperative
  overshoot observable.
