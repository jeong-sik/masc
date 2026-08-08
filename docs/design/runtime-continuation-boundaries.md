# Runtime Continuation Boundaries

Date: 2026-06-14

## Purpose

OAS exposes typed continuation boundaries so hosts can accept user input while
an agent is busy without inserting it into unsafe positions in the provider
history. The host (the downstream coordinator) owns the queue and UI. OAS owns
the boundary policy.

## Boundaries

| Boundary | Ordinary input policy |
| --- | --- |
| `Before_provider_request` | Apply now |
| `Provider_streaming_reasoning` | Queue until a safe boundary |
| `Before_assistant_tool_use` | Queue until tool results are closed |
| `After_assistant_tool_use_before_results` | Reject/ignore for the current turn |
| `After_tool_results_before_next_provider_request` | Apply now |
| `After_final_answer` | Apply as next turn input |

Explicit operator interrupts are separate from ordinary input. An interrupt may
cancel/checkpoint/resume the running turn, but it is not a pause or stop command.

Ordinary input that arrives while a turn is busy is deliberately not a runtime
lifecycle phase. A busy agent with queued input should keep running until it
reaches a safe boundary or receives an explicit interrupt.
