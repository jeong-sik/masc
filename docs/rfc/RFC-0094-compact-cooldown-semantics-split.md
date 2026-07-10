---
rfc: "0094"
title: "Compact cooldown semantics split decision record"
status: Superseded
created: 2026-05-17
updated: 2026-07-10
author: vincent
supersedes: []
superseded_by: "KEEPER-STATE-OWNERSHIP"
related: ["0002", "0088"]
implementation_prs: [15716]
---

# RFC-0094: Compact cooldown semantics split decision record

The original implementation separated compact check/write timing, but its
continuity-state terminology is no longer an ownership contract. This file
remains so the implemented PR and historical references do not become dangling.

Current compaction decisions are owned by typed compact policy, Keeper state
machine events, and checkpoint evidence. Model prose does not update cooldowns
or lifecycle state. See [`KEEPER-STATE-OWNERSHIP.md`](../KEEPER-STATE-OWNERSHIP.md).
