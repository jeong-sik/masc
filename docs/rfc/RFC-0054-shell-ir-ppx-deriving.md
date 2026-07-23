---
rfc: "0054"
title: "Withdraw code generation for command-policy GADTs"
status: Withdrawn
created: 2026-05-09
updated: 2026-07-13
author: jeong-sik
supersedes: []
superseded_by: null
related: ["0005", "0057"]
implementation_prs: []
---

# RFC-0054: Withdraw code generation for command-policy GADTs

## Decision

This RFC is withdrawn together with RFC-0005's command-policy phases. Generating
walkers for a GADT that encodes local command rank and inferred sandbox policy
would make the obsolete hierarchy easier to extend, not improve the execution
boundary.

Shell IR may still use ordinary exhaustive OCaml types for syntax, argv, path,
redirect, and selected-sandbox facts. No generated walker may derive
authorization from executable constructors. A future code generator needs a
live schema consumer and a separate RFC; this withdrawn POC is not that
authority.
