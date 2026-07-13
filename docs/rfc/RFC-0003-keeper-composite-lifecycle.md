---
rfc: "0003"
title: "Withdraw composite lifecycle projection hierarchy"
status: Withdrawn
created: 2026-04-14
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0001", "0002"]
implementation_prs: []
---

# RFC-0003: Withdraw composite lifecycle projection hierarchy

## Decision

Withdraw the composite observer design that synchronized multiple collapsed
Keeper phase sets and treated their combination as a runtime contract.

Its formal ground included the deleted `KeeperCoreTriad` and `StateProduct`
families. Keeping a second composite lifecycle vocabulary would recreate the
same hierarchy and SSOT drift after those models were removed.

Current observers consume typed source events. They may expose ordering,
correlation, and durable evidence, but they cannot authorize tools, schedule a
Keeper, mutate Task or Goal state, or manufacture pause/terminal outcomes.
Keeper lane behavior remains owned by the canonical per-Keeper runtime; optional
HITL is a nonblocking Gate that later wakes only the originating lane.

Historical prose and implementation are recoverable from Git and are not
current runtime authority.
