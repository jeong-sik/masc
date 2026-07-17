---
rfc: "shared-admission-primitive-knob-binding-policy"
title: "Withdraw shared MASC admission and knob-binding policy"
status: Withdrawn
created: 2026-07-17
updated: 2026-07-17
author: vincent
supersedes: []
superseded_by: "0000"
related: ["0153", "0158", "0206", "0225", "0334"]
implementation_prs: []
---

# Withdraw shared MASC admission and knob-binding policy

## Decision

MASC will not implement a generic fleet/lane cardinality admission primitive.
The former proposal's `Admission.Make`, `Skip_if_full`, `Wait_fifo`, and
budget-shaped knob registry are retired and must not be used as implementation
guidance.

## Boundary

- Explicit provider/account concurrency is a typed deployment fact enforced by
  OAS at the exact endpoint/account dispatch boundary. `None` is unbounded.
- MASC owns product operations and per-Keeper lanes. A waiting operation parks;
  it does not deny, drop, pause, or serialize an unrelated owner.
- Auto Judge work is FIFO within the exact `(BasePath, Keeper)` owner. There is
  no fleet cardinality cap in MASC.
- Counts, queue latency, utilization, token usage, and cost are observations.
  They never become implicit execution authority.
- Dead configuration is deleted. Unknown retired fields fail explicitly at the
  parser boundary; they are not wired into a replacement limiter.

## Retired implementation shapes

- a shared MASC `Admission.Make` library;
- config-key name scanning to infer whether a knob is admission-shaped;
- `Skip_if_full` as a substitute for unbounded execution;
- cross-Keeper FIFO waiting behind one lane/global slot pool;
- MASC duplication of OAS provider admission;
- compatibility flags or dual paths for the withdrawn design.

## Surviving work

Continue deleting dead concurrency/budget fields and their tests. Preserve
explicit Runtime-to-OAS provider declarations, owner-local durable parking and
wake, typed failure, and dashboard observation. RFC-0000 is the governing
architecture.
