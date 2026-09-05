---
title: Design Decisions
description: The major design decisions settled through the RFC archive under docs/rfc/.
---

The MASC architecture was settled incrementally through roughly 270 internal RFCs and measurement records archived under `docs/rfc/`. The major decision areas:

---

## 1. Execution isolation and the gate

* **Sandbox profiles**: Shell execution is confined to `docker`, `microvm`, or `remote_ssh`. A keeper without an accepted profile is refused.
* **Operator gate**: Destructive commands stop the turn and enter the approval queue. It is an authorization workflow, not a sandbox.

---

## 2. Task claiming and coordination

* **Optimistic claiming (CAS)**: Task transitions are guarded by `expected_version`; a mismatched version is rejected, and a task one agent has claimed cannot be taken by another. This protects task ownership — it does not prevent concurrent edits to source files.
* **Board**: The asynchronous channel where people and agents exchange state, directives, and evidence.

---

## 3. Multi-model deliberation (Fusion)

* **Asynchronous out-of-band deliberation**: The same prompt fans out to N models and a judge synthesizes. The measured trade-off (+3.7pp accuracy at roughly 4x cost and 7x latency, cited by RFC-0252) kept it out of the main loop, as the asynchronous advisory tool `masc_fusion`. See the [Fusion page](/architecture/fusion/).

---

## 4. Long-term memory (Memory OS)

* **Two stores**: Each keeper has an ordinary fact store and a source-bound store with invalidation records.
* **Usage-driven reinforcement (RFC-0418)**: The stagnant reobservation counter is gone; retrieval, citation, and revision events are recorded in a dedicated sidecar.
* **Librarian selection**: Curation is the librarian lane's selection — keep, or drop with a reason — with no numeric scores or decay curves. See the [Memory OS page](/architecture/memory-os/).

---

## 5. Performance observation

* **Scheduler-lag probe**: A probe fiber on a 100ms interval records wake overshoot into a one-minute ring and exposes p50 and over-one-second stalls through `/health` diagnostics (`lib/core/scheduler_lag.ml`).
* **Differential terminal rendering**: Row prefixes are precomputed and buffers reused, so only what changed is redrawn.
* **Conditional revalidation (304)**: Dashboard responses carry a weak ETag; a matching `If-None-Match` gets a bodyless 304, cutting the payload of high-frequency polling.

---

> The original RFCs are preserved in the repository's `docs/rfc/` directory.
