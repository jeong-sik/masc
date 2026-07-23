---
rfc: "0271"
title: "Withdraw progress-based turn rejection and pause"
status: Withdrawn
updated: 2026-07-13
---

# RFC-0271: Withdraw progress-based turn rejection and pause

| | |
|---|---|
| Status | Withdrawn |
| Withdrawn | 2026-07-13 |
| Reason | Tool classes and fixed budgets cannot objectively decide whether a Keeper turn was useful. |

## Historical disposition

The former path classified a response as `No_usable_progress`, retried it, and
eventually paused the Keeper. That heuristic and its completion-contract state
are removed. Empty or malformed provider responses remain explicit OAS/runtime
errors; semantic Task completion is judged by the configured LLM without
blocking the Keeper lane.

This document is historical only and defines no active behavior.
