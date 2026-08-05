---
rfc: "0288"
title: "Remove per-Keeper goal-horizon fields"
status: Implemented
created: 2026-06-23
updated: 2026-07-10
author: vincent
supersedes: ["0282"]
superseded_by: "KEEPER-STATE-OWNERSHIP"
related: ["0294"]
implementation_prs: []
---

# RFC-0288: Remove per-Keeper goal-horizon fields

The short/mid/long keeper-goal tuple is removed. A Keeper may carry
ordinary authored intent, while operational objectives live in the typed Goal
and Task domains. No scheduler or lifecycle decision may infer control state
from keeper prose.

This record remains for live migration comments such as workspace task reclaim.
See [`KEEPER-STATE-OWNERSHIP.md`](../KEEPER-STATE-OWNERSHIP.md).
