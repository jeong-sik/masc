---
rfc: "0155"
title: "Withdraw centralized operational policy log taxonomy"
status: Withdrawn
created: 2026-05-21
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0088", "0089", "0148", "0149", "0154"]
implementation_prs: []
---

# RFC-0155: Withdraw centralized operational policy log taxonomy

## Decision

Withdraw the proposed closed sum that encoded watchdog, admission, verifier,
runtime-exhaustion, and Task policy categories in the generic logger.

Each source module emits a typed domain event and an explicit severity. The log
sink serializes that event; it does not reclassify free text or translate an
operational category into Keeper lifecycle or authorization. The current
contract is `docs/spec/18-log-severity-taxonomy.md`.
