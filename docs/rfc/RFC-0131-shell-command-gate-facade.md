---
rfc: "0131"
title: "Withdraw policy-bearing shell command facade"
status: Withdrawn
created: 2026-05-21
updated: 2026-07-13
implementation_prs: []
---

# RFC-0131 — Withdraw policy-bearing shell command facade

Typed argv parsing, BasePath/path jail, and sandbox confinement remain
objective execution invariants. Redirect, command, product, and caller meaning
do not form a second authorization engine. External execution reaches the same
opaque Keeper Gate as every other effect.
