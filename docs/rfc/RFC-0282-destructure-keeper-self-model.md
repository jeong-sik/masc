---
rfc: "0282"
title: "Reduce Keeper persona to ordinary instructions"
status: Implemented
created: 2026-06-22
updated: 2026-07-10
author: vincent
supersedes: ["0275", "0276"]
superseded_by: "KEEPER-STATE-OWNERSHIP"
related: ["0288"]
implementation_prs: []
---

# RFC-0282: Reduce Keeper persona to ordinary instructions

Structured will/needs/desires fields are removed. Authored persona content is
carried by ordinary instructions and world description; it is not mutable
cognitive state. This concise record remains because persona parser, validator,
renderer, and tests cite RFC-0282.

See [`KEEPER-STATE-OWNERSHIP.md`](../KEEPER-STATE-OWNERSHIP.md).
