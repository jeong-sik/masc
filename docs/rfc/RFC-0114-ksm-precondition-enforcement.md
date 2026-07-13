---
rfc: "0114"
title: "Withdraw compact-retry and lifecycle guard model"
status: Withdrawn
created: 2026-05-17
updated: 2026-07-13
implementation_prs: []
---

# RFC-0114 — Withdraw compact-retry and lifecycle guard model

The modeled compact-retry exhaustion, automatic guard rejection, and terminal
promotion were removed. Objective state preconditions remain local to their
typed mutation; they do not create Keeper pause/stop policy.
