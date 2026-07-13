---
rfc: "0322"
title: "Withdraw repository-catalog read authorization"
status: Withdrawn
created: 2026-07-08
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0006", "0219", "0312"]
implementation_prs: []
---

# RFC-0322: Withdraw repository-catalog read authorization

## Decision

This RFC is withdrawn. It tried to make a repository catalog gate less painful
by adding self-registration rules, but kept catalog membership as read
authorization. That is product-specific policy inside filesystem access and
turns missing metadata into an operator dependency.

Repository mappings are advisory discovery/default-scope data, as recorded by
RFC-0312. Filesystem access is decided from objective typed paths, base-path
jail, and selected-sandbox containment. A missing catalog entry does not deny a
Keeper access to a path already inside its authorized sandbox. Cross-sandbox
escape, invalid paths, unavailable mounts, and real filesystem permissions
remain explicit execution errors.

Repository creation, clone, push, or other actual external effects use the
ordinary Keeper Gate. The Gate receives an opaque operation and normalized
input; it does not know repository-hosting products or catalog policy.
