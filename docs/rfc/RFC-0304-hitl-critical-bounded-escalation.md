---
rfc: "0304"
title: "Withdraw Critical-class HITL escalation"
status: Withdrawn
created: 2026-07-04
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0303", "0318", "0319"]
implementation_prs: []
---

# RFC-0304: Withdraw Critical-class HITL escalation

## Decision

This RFC is withdrawn. A special Critical class, elapsed-time escalation, and
operator-must-decide branch form a policy hierarchy from labels and timers.
They also make the waiting tool call or Keeper fiber the unit of suspension.

HITL is instead a durable, request-local Gate decision:

- the effect request is parked, not the Keeper lane;
- the Keeper may continue other work and is awakened when a decision arrives;
- approval is consumed once against the exact Keeper, operation, and input;
- an unsettled request remains visible without timer-derived approval,
  rejection, escalation rank, or fleet pause;
- persistence and delivery failures are explicit.

Operators may still decide any pending request. No request is assigned a
higher authorization class by MASC.
