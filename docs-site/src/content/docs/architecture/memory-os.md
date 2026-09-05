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
