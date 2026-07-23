---
rfc: RFC-0082
title: Withdraw automatic blocker escalation and recovery
author: jeong-sik
created: 2026-05-14
updated: 2026-07-13
status: Withdrawn
supersedes: []
related: ["0042", "0068"]
---

# RFC-0082 — Withdraw automatic blocker escalation and recovery

This RFC converted runtime observations into blocker latches, diagnostic
budgets, automatic pause/resume behavior, and dashboard override semantics.
That hierarchy is removed.

A provider or tool failure remains an explicit observation. The Keeper lane
continues and may use another configured runtime or perform another activity.
Only explicit operator control or a durable Dead tombstone changes lifecycle
state. This document is historical only.
