---
rfc: "0117"
title: "Withdraw runtime health cooldown hierarchy"
status: Withdrawn
created: 2026-05-17
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0072", "0113", "0114", "0115", "0116"]
implementation_prs: [15957]
---

# RFC-0117: Withdraw runtime health cooldown hierarchy

## Decision

Withdraw the Healthy/Degraded/Unhealthy classification, failure thresholds,
shared provider cooldowns, and time-based admission behavior proposed here.

Provider outcomes remain typed observations. They may inform the configured
LLM's next runtime choice, but they do not create a hidden Keeper lifecycle,
shared-lane denial, or automatic pause. OAS exposes provider/model facts; MASC
owns Keeper orchestration without teaching OAS MASC policy.

Historical implementation PRs remain available in Git and are not current
runtime authority.
