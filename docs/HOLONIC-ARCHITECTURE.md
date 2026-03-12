# MASC Holonic Architecture

**Date**: 2026-01-09  
**Author**: 윤정식 (Seungji Yun)  
**Status**: Vision document (concept, not validated)

---

## Scope

This document keeps only the architectural layers that map to concrete coordination concerns in MASC. It is a conceptual aid, not a delivery plan or an implementation checklist.

Earlier revisions mixed actionable architecture with speculative "mind/noosphere/void" language. Those sections were removed because they were not tied to code ownership, validation, or operational behavior.

---

## Layer Summary

| Level | Name | Focus | Current status |
|-------|------|-------|----------------|
| 0 | Agent | Single worker lifecycle, capabilities, local state | Implemented |
| 1 | Room | Shared task/message/state surface for collaboration | Implemented |
| 2 | Organization | Roles, policy, metrics, selection | Partial |
| 3 | Federation | Cross-room or cross-cluster coordination | Experimental |
| 4 | Swarm | Emergent multi-agent search and selection | Research |
| 5 | Institution | Durable memory, succession, long-lived norms | Research |

---

## What Each Layer Means

### Level 0: Agent

The smallest executable unit in MASC. An agent has identity, capabilities, and a current workload.

Representative concerns:
- task execution
- model/runtime selection
- local lifecycle and status

### Level 1: Room

The collaboration boundary. A room defines who can see messages, tasks, decisions, and shared state.

Representative concerns:
- task backlog
- broadcasts and direct coordination
- shared persistence

### Level 2: Organization

Policy and structure above individual rooms. This is where routing, role constraints, and quality controls start to matter.

Representative concerns:
- role or capability-based assignment
- approval rules
- metrics and fitness signals

### Level 3: Federation

Coordination across room or deployment boundaries.

Representative concerns:
- discovery between coordination domains
- delegation across boundaries
- shared trust/auth contracts

### Level 4: Swarm

Higher-order behavior that emerges from repeated agent interactions rather than from a single hard-coded workflow.

Representative concerns:
- search strategy selection
- adaptive worker allocation
- evaluation and retry policies

### Level 5: Institution

Long-lived memory and operating norms that survive individual runs or agents.

Representative concerns:
- episodic/semantic/procedural memory
- succession and handoff quality
- persistent policies and historical learning

---

## Current Mapping to the Codebase

| Layer | Current examples |
|-------|------------------|
| Agent | tool execution, keeper runtime, worker spawning |
| Room | board, tasks, messages, room persistence |
| Organization | metrics, policy, selection, approval surfaces |
| Federation | A2A and remote delegation surfaces |
| Swarm | team sessions, bounded runs, search/speculation loops |
| Institution | handoff, keeper continuity, memory, goal review |

This mapping is descriptive, not exhaustive. Modules will continue to move as the implementation changes.

---

## Design Constraints

- Prefer operational boundaries over metaphors.
- Keep each layer explainable in terms of ownership, state, and failure modes.
- Do not claim a layer is implemented unless there is runnable code and a validation path.
- Treat swarm/institution work as incremental extensions to the existing room/task model, not as separate universes.

---

## Research Pointers

| Layer | Reference | Reason for inclusion |
|-------|-----------|----------------------|
| Organization | [ACM TOSEM MAS](https://dl.acm.org/doi/10.1145/3712003) | role and coordination structures |
| Federation | [A2A Protocol](https://arxiv.org/html/2501.06322v1) | inter-agent/inter-system delegation |
| Swarm | [EvoAgent](https://arxiv.org/abs/2406.14228) | evolutionary search and selection |
| Institution | [Hippocampus AI](https://pmc.ncbi.nlm.nih.gov/articles/PMC11591613/) | durable memory framing |

---

## Practical Reading

Use this document when you need a vocabulary for discussing scale:
- agent to room
- room to policy
- policy to federation
- federation to swarm/institution research

Do not use this document as evidence that a feature already exists. For current behavior, check the runbooks and the spec first.
