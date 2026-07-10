---
rfc: "0276"
title: "Remove Keeper social-model self-report protocol"
status: Implemented
created: 2026-06-22
updated: 2026-07-10
author: jeong-sik
supersedes: ["0275"]
superseded_by: "KEEPER-STATE-OWNERSHIP"
related: ["0239", "0282"]
implementation_prs: []
---

# RFC-0276: Remove Keeper social-model self-report protocol

The model-declared social header, parser, registry, persisted record, metrics,
and dashboard surface are retired. The decision record remains because live
turn code cites RFC-0276 for the replacement contract.

The surviving replacement is runtime-observed delivery classification in
`keeper_unified_turn_success`: typed tool outcomes and visible response facts,
not a model-authored label. See
[`KEEPER-STATE-OWNERSHIP.md`](../KEEPER-STATE-OWNERSHIP.md).
