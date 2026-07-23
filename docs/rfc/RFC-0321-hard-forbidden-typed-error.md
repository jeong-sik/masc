---
rfc: "0321"
title: "Withdraw unconditional static tool-block proposal"
status: Withdrawn
created: 2026-07-10
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0318", "0319"]
implementation_prs: []
---

# RFC-0321: Withdraw unconditional static tool-block proposal

## Decision

This RFC is withdrawn. It proposed improving the error representation of an
unconditional governance rejection while preserving that rejection. The
underlying static policy has now been removed, so implementing a new OAS
`Block` path for it would retain the wrong product semantics in a better type.

MASC must not recreate the removed behavior under a renamed reason code,
typed risk band, command catalog, or pre-tool hook.

## Current boundary

- Keeper Gate owns explicit HITL requests and their LLM/operator decisions.
- Shell IR parses and executes commands without product-specific static tool
  denial.
- Typed `cwd` and redirect scopes remain validated.
- The selected runtime sandbox owns process containment.
- Actual tool, spawn, sandbox, permission, and non-zero-exit failures remain
  explicit error results and observable events.
- One Keeper's rejected or failed action does not pause other Keeper lanes.

## Why no OAS change follows from this RFC

OAS should expose general hook and tool-result semantics, but it must not learn
about a deleted MASC governance rule. A general OAS error-model improvement may
still be proposed from an OAS-owned use case. This retired MASC policy is not
such a use case and creates no cross-repository implementation requirement.

## Verification

The active MASC source and tests must contain no unconditional static-tool-block
branch derived from the retired governance/risk hierarchy. Error-path tests
must instead cover real execution failures and explicit Keeper Gate decisions.
