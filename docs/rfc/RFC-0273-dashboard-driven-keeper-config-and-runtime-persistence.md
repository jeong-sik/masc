---
rfc: "0273"
title: "Withdraw policy-bearing Keeper configuration tiers"
status: Withdrawn
created: 2026-06-21
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0038", "0233", "0335"]
implementation_prs: []
---

# RFC-0273: Withdraw policy-bearing Keeper configuration tiers

## Decision

This RFC is withdrawn. It mixed valid configuration persistence work with
per-tool access policy, storage-derived policy tiers, and a separate audit
hierarchy. Keeping those together would let dashboard configuration recreate
the Keeper restrictions removed from runtime.

The retained boundaries are independent:

- authenticated dashboard writes update their owning product configuration and
  return explicit validation/persistence errors;
- `runtime.toml` remains the SSOT for Keeper-to-Runtime assignment;
- Keeper persona and instructions remain Keeper configuration;
- exact Always Allowed rules are Gate records, not descriptor allowlists or
  guessed tool permissions;
- the dashboard may configure and observe Gate decisions, but it does not turn
  configuration storage scope into an authorization rank.

Future dashboard persistence work should be specified per owning store and
must not revive the withdrawn tool-policy surface.
