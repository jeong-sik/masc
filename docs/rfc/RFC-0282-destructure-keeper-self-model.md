---
rfc: "0282"
title: "Keeper authored content is ordinary instructions"
status: Implemented
created: 2026-06-22
updated: 2026-07-10
author: vincent
supersedes: ["0275"]
superseded_by: "KEEPER-STATE-OWNERSHIP"
related: []
---

# RFC-0282: Keeper authored content is ordinary instructions

Structured will/needs/desires fields are removed. Authored keeper content is
carried by ordinary instructions and world description; it is not mutable
cognitive state. This concise record remains because keeper parser, validator,
renderer, and tests cite RFC-0282.

See [`KEEPER-STATE-OWNERSHIP.md`](../KEEPER-STATE-OWNERSHIP.md).
