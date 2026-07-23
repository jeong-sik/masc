---
rfc: "0222"
title: "Withdraw harness-owned Task completion"
status: Withdrawn
created: 2026-06-09
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0199", "0220", "0221"]
implementation_prs: []
---

# RFC-0222: Withdraw harness-owned Task completion

## Decision

This RFC is withdrawn. A harness result is useful evidence, but it is not the
universal authority for Task completion. The old design divided Tasks into
machine-checkable and subjective classes and introduced a second completion
path whose eligibility depended on local classification.

The replacement has one semantic boundary: the configured LLM judges Task
completion from the Task, its contract, structured evidence, and execution
receipts. Harness results remain ordinary evidence. Missing or failed evidence
is explicit input to that judgment, not a hard-coded completion transition.
The Keeper lane does not pause while a completion judgment is pending.
