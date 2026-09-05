---
title: Design Decisions
description: Architectural evolution and key engineering decisions archived from internal RFCs.
---

The MASC architecture evolved through ~260 internal RFCs and empirical test runs archived in `docs/rfc/`. Key decision domains include:

---

## 1. Execution Isolation & Operator Gate

* **Docker Sandbox Profiles**: Confines shell execution within container boundaries to protect the host filesystem.
* **Operator Gate**: Pauses agent turns on destructive operations (force-push, file deletion, remote deployment) pending TUI/CLI confirmation.

---

## 2. Concurrency Control & Atomic Claiming

* **Atomic Claiming**: Secures exclusive task ownership through compare-and-swap writes guarded by an `expected_version` on the append-only ledger, preventing concurrent file overwrites across agents.
* **Shared Event Feed (Board)**: Asynchronous broadcast channel exchanging state, directives, and decision evidence between agents and operators.

---

## 3. Multi-Model Deliberation (Fusion)

* **Out-of-Band Advisory**: Fans out prompts across multiple model families and synthesizes verdicts via a judge model to cross-verify single-model blind spots.
* **Cost/Latency Trade-offs**: Incurs ~4x cost and ~7x latency, leading to isolation into an asynchronous advisory tool (`masc_fusion`) rather than the core turn loop.

---

## 4. Causal Persistence (Memory OS)

* **Causal Graph Nodes**: Tracks trigger, decision, and outcome edges instead of flat vector embeddings.
* **Usage-Driven Reinforcement (RFC-0418)**: Replaced stagnant re-observation counters with typed event sidecars logging retrievals, retractions with citation chains, and revisions.
* **Weight Decay**: Decays transient debug logs over time while permanently retaining constitutional invariants and core decisions.

---

## 5. Performance & Sub-Millisecond Diagnostics

* **Main-Domain Scheduler Lag & GC Monitoring**: 100ms probe fiber tracking event loop execution delays in a 1-minute ring buffer alongside GC quick stats on `/health`.
* **Zero-Allocation TUI & Differential Rendering**: Precomputed row prefixes, single-pass terminal slicing, and buffer reuse for flicker-free 60fps terminal updates.
* **Sub-Millisecond 304 Fast-Path**: Server-side weak ETag caching and client conditional browser revalidation cutting polling overhead to 0 payload bytes and 0ms compute.

---

> Technical proposals are preserved in the repository's `docs/rfc/` directory.

