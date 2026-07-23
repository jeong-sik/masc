---
rfc: "0212"
title: "Withdraw Keeper exposure policy axis"
status: Withdrawn
created: 2026-06-03
updated: 2026-07-13
---

# RFC-0212 — Withdraw Keeper exposure policy axis

Separating routing from exposure was insufficient because exposure itself was
an unnecessary authorization hierarchy. Dispatch tags route to handlers only.
They never decide model visibility, authorization, or metric severity.
