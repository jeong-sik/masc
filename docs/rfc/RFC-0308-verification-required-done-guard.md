---
rfc: "0308"
title: "Withdraw verifier-required Task routing"
status: Withdrawn
created: 2026-07-04
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0220", "0221", "0311", "0323"]
implementation_prs: []
---

# RFC-0308: Withdraw verifier-required Task routing

## Decision

This RFC is withdrawn. Whether a Task contract or Goal field happens to be
present is not an objective basis for splitting completion into weak and strong
lanes. The proposed routing could strand a Task behind a verifier identity and
turn one unavailable participant into a Keeper-wide stop.

Task completion has one semantic decision boundary: the configured LLM judges
the Task, Goal context, contract, evidence, and receipts. The verdict is
persisted and observable. A pending or unavailable judgment does not prevent
the Keeper from doing other work, and no contract-presence heuristic chooses a
different completion FSM.
