---
rfc: "0337"
title: "Withdraw deterministic evidence-gate semantics"
status: Withdrawn
created: 2026-07-10
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0109", "0311", "0323"]
implementation_prs: []
---

# RFC-0337: Withdraw deterministic evidence-gate semantics

## Decision

This RFC is withdrawn. It preserved a mandatory trusted-reference floor for
every Task and layered semantic review above it. That is still a hierarchy:
local evidence shape can reject work before the configured judge evaluates the
actual Task.

Evidence parsing may establish objective facts such as a valid path or receipt
identity. It does not establish completion. The configured LLM owns that
judgment, records its provenance, and may use structured evidence without a
mandatory kind/count floor. Unavailable judgment is explicit and request-local;
the Keeper remains active.
