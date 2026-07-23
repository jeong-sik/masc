---
rfc: "0311"
title: "Withdraw deterministic evidence floors"
status: Withdrawn
created: 2026-07-06
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0109", "0199", "0308", "0337"]
implementation_prs: []
---

# RFC-0311: Withdraw deterministic evidence floors

## Decision

This RFC is withdrawn. It correctly rejected substring incantations, but
replaced them with mandatory local evidence kinds and a deterministic floor
above the semantic judge. Evidence shape is not a universal truth about whether
arbitrary work is complete.

Typed evidence references remain useful as model context and for resolving
paths or receipts without silent failure. Their presence, kind, or count does
not decide completion. The configured LLM judges the Task against its context
and evidence. If judgment cannot run, the result is explicit and the Keeper
continues other activity; no static evidence rule becomes a hidden stop.
