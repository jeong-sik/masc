---
rfc: "0263"
title: "Withdraw actor-priority turn preemption"
status: Withdrawn
created: 2026-06-19
updated: 2026-07-13
---

# RFC-0263 — Withdraw actor-priority turn preemption

An Owner role does not interrupt or outrank an in-flight Keeper turn. New
messages enter that Keeper's FIFO lane; the Connector may acknowledge that the
Keeper is busy. Other Keeper lanes remain independent.
