---
rfc: "0118"
title: "Withdraw terminal runtime projection contract"
status: Withdrawn
created: 2026-05-17
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0072", "0113", "0114", "0115", "0116", "0117"]
implementation_prs: [15963]
---

# RFC-0118: Withdraw terminal runtime projection contract

## Decision

Withdraw the `KeeperCoreTriad` terminal projection and its attempt to suppress
runtime selection for a collapsed set of Keeper phases.

The projection mixed lifecycle, runtime availability, and routing policy. A
provider/model failure is a typed local observation and does not itself stop a
Keeper. Explicit operator stop and durable process death remain separate
lifecycle facts.

The deleted formal model and historical implementation remain recoverable from
Git; neither is current runtime authority.
