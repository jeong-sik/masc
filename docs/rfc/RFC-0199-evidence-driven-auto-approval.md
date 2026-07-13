---
rfc: "0199"
title: "Withdraw deterministic task-completion auto approval"
status: Withdrawn
created: 2026-05-27
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0109", "0222", "0311"]
implementation_prs: []
---

# RFC-0199: Withdraw deterministic task-completion auto approval

## Decision

This RFC is withdrawn. A fixed evidence-claim vocabulary and a local evaluator
cannot determine that arbitrary Task work is complete. Treating selected
artifacts or checks as automatic completion authority merely replaces a string
heuristic with a typed heuristic.

Evidence may be structured and attached to the Task as model context. The
configured completion LLM judges whether the work satisfies the Task. Its
verdict and provenance are recorded explicitly. If judgment is unavailable,
the Task remains unsettled while the Keeper continues other activity; no
deterministic evidence shape silently completes or globally blocks work.
