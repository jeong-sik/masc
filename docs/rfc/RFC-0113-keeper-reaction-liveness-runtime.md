---
rfc: "0113"
title: "Withdraw KeeperReactionLiveness runtime hierarchy"
status: Withdrawn
created: 2026-05-17
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0002", "0003", "0020", "0042", "0072"]
implementation_prs: [15937]
---

# RFC-0113: Withdraw KeeperReactionLiveness runtime hierarchy

## Decision

Withdraw the five-level `KeeperReactionLiveness` mirror and remove its formal
model from the active specification set.

The model combined Board receipt tracking, verification, Goal resolution, Task
transition, timeout escalation, and Keeper lifecycle mutation into one hierarchy.
Those are independent product boundaries. A missing receipt or delayed verifier
must remain an explicit observation; it must not manufacture an automatic pause,
terminal state, escalation level, or cross-Keeper authority.

Current contracts are narrower:

- every Keeper owns a durable FIFO stimulus lane;
- Board, Goal, Task, Job, Connector, and Gate publish typed stimuli without
  acquiring Keeper lifecycle authority;
- the configured LLM decides semantic relevance and the next action;
- optional HITL resolves through a durable, nonblocking Gate and wakes the
  originating lane;
- only an explicit operator stop or a durable process tombstone can end the
  Keeper lifecycle.

Historical implementation PRs remain available in Git. They are not a source of
current runtime policy.
