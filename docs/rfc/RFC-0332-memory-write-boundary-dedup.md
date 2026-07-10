---
rfc: "0332"
title: "Rejected heuristic memory write dedup draft"
status: Rejected
created: 2026-07-08
updated: 2026-07-10
author: vincent
supersedes: []
superseded_by: "KEEPER-STATE-OWNERSHIP"
related: ["0247"]
implementation_prs: []
---

# RFC-0332: Rejected heuristic memory write dedup draft

The draft proposed lexical-similarity thresholds at the memory write boundary.
That is not an accepted production contract: an arbitrary score must not merge
or silently discard durable memory.

Memory writes require a typed, observable outcome. Any semantic merge decision
belongs behind an explicit LLM judgment boundary with evidence; otherwise rows
remain distinct. See [`KEEPER-STATE-OWNERSHIP.md`](../KEEPER-STATE-OWNERSHIP.md).
