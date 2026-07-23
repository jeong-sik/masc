---
rfc: "typed-egress-resource-capability"
title: "Withdraw product-specific egress effect classification"
status: Withdrawn
created: 2026-07-08
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0107", "0309"]
implementation_prs: []
---

# Withdraw product-specific egress effect classification

## Decision

This RFC is withdrawn. It generalized one repository-hosting CLI bypass into a
host, HTTP method, resource-path, and product taxonomy. Typing that taxonomy
would still make generic egress know vendor APIs and guess operation meaning;
every new endpoint would extend the same policy burden.

The replacement boundary is uniform:

- outbound network containment and actual credential availability are objective
  runtime facts;
- a concrete outbound external effect reaches the product-neutral Keeper Gate
  with an opaque operation identity and normalized input;
- the Gate settles it by exact Always Allowed, configured LLM Auto Judge, or
  non-blocking HITL;
- no generic module matches a CLI name, vendor host, HTTP path, method, request
  body, or guessed remote-resource durability to rank authorization;
- network, DNS, TLS, authentication, transport, and response failures remain
  explicit execution results.

Vendor-aware request construction belongs in its Connector/tool adapter, not in
OAS, Shell IR, generic egress, or Keeper Gate.
