# OAS Provider Timeout Contract

Status: active as of 2026-07-15.

MASC has one LLM cancellation boundary: the OAS Provider transport call.

- Streaming requests use inter-event idle timeout. Thinking, answer deltas,
  tool progress, heartbeat, substrate progress, and terminal events all refresh
  liveness. There is no total stream wall-clock cutoff.
- Non-streaming requests use one body timeout around the Provider request/body
  operation. Connect/header setup does not add another body deadline.
- `Masc_oas_bridge` observes cancellation and converts unexpected exceptions;
  it does not install a timeout.
- Keeper features, HITL summary, librarian, compaction, consolidation, vision,
  Fusion fan-out, and judge orchestration must not wrap Provider work in local
  wall-clock deadlines.
- A failed retryable Auto Judge summary remains durable. Only an explicit
  operator action may request one new attempt.

`Masc_eio_env` remains domain-local because OAS HTTP transport needs handles
owned by the calling Eio domain. Its clock is passed to Provider transport; it
is not evidence of a bridge-level timer.

Timeout and retry budgets may be recorded for diagnostics, but may not cancel,
skip, extend, or replay LLM work outside the Provider boundary.
