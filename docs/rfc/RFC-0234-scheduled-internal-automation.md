---
rfc: "0234"
title: "Withdraw schedule-specific approval hierarchy"
status: Withdrawn
created: 2026-06-12
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0220", "0233"]
implementation_prs: []
---

# RFC-0234: Withdraw schedule-specific approval hierarchy

## Decision

This RFC is withdrawn. Its durable schedule ledger and opaque consumer payload
were useful directions, but the design embedded effect classes, a separate
human-principal rule, and schedule-owned authorization. That duplicates the
Keeper Gate and makes Scheduler understand policy it cannot judge.

The Scheduler boundary is now:

1. persist an opaque request, its due condition, ownership, and provenance;
2. wake the owning Keeper lane when it becomes due;
3. let the consumer decode its own payload;
4. submit each actual external effect to the ordinary Keeper Gate at execution
   time.

Scheduling is neither an authorization grant nor a reason for a special
approval hierarchy. Exact Always Allowed, configured LLM Auto Judge, and
non-blocking HITL apply in the same way as every other external effect. One
pending scheduled effect never blocks unrelated work or another Keeper lane.
