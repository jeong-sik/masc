---
title: Memory OS Architecture
description: Local causal graph-based persistent memory surviving session resets.
---

Memory OS is a local persistent memory subsystem that retains causality and intent across context window truncations and process restarts.

---

## Memory Pipeline

```mermaid
flowchart LR
    subgraph Work ["Keeper Turn Execution"]
        T["Code Edits & Tool Output"] --> OBS["Observation Stream"]
    end

    subgraph Memory ["Memory Storage"]
        OBS --> G["Causal Relationship Graph"]
        G --> N1[("Key Decisions<br/>(Architecture & Invariants)")]
        G --> N2[("Transient Data<br/>(Debug Logs & Temp Output)")]
    end

    subgraph Caretaker ["Background Curator"]
        LIB["Librarian Worker"]
        LIB -->|"Retain high-value directives"| N1
        LIB -->|"Prune and decay stale outputs"| N2
    end

    N1 -.->|"Inject context on next task"| Work
```

---

## Core Primitives

### 1. Causal Graph Storage
Rather than flat text embeddings, Memory OS records directed edges between task triggers, technical decisions, and empirical execution outcomes.

### 2. Node Lifecycle & Decay
* **Retained Nodes**: Operator directives, invariant violations, and verified architectural decisions.
* **Transient Nodes**: Ephemeral build outputs, intermediate tool errors, and scratch data slated for decay.

### 3. Asynchronous Curation (Librarian Worker)
Graph deduplication and compression run in background fibers decoupled from the active Keeper turn execution loop.

---

## Usage-Driven Reinforcement (RFC-0418)

In conventional memory systems, a memory node is often reinforced when the identical claim is re-observed. However, LLM generation variability means identical claims are rarely emitted byte-for-byte, leaving static re-observation counters stagnant.

Memory OS establishes that **memory solidifies when retrieved and applied, not passively re-observed**:

```mermaid
flowchart TD
    subgraph Execution ["Turn Execution"]
        Q["keeper_memory_search"] --> RET["1 Fact = 1 Retrieval Event"]
        RET --> USE["Injected into Context"]
    end

    subgraph Sidecar ["Per-Keeper Event Sidecar"]
        RET -.->|"Log retrieval"| EV["<keeper>.memory-events.jsonl"]
        REC["Retract Claim"] -.->|"Log citation chain"| EV
        REV["Revise Claim"] -.->|"Log revision"| EV
    end

    subgraph Facts ["Current Facts Store"]
        EV ==>|"Derived Salience"| DB["<keeper>.memory-current.json"]
    end
```

### 1. Typed Sidecar Event Stream
Each Keeper records lifecycle actions into an append-only JSONL sidecar (`<keeper>.memory-events.jsonl`):
* `retrieval`: Recorded per fact returned by `keeper_memory_search`.
* `citation`: Recorded when a retract or update operation cites a prior fact.
* `revision`: Recorded when an existing claim's boundary or text is formally revised.

### 2. Elimination of Dead Counters
The legacy `fact.reinforcement` integer counter in the fact store has been removed. High confidence and confirmed badges in the TUI reflect verified retrieval velocity and explicit citations rather than duplicate ingestion counts.

