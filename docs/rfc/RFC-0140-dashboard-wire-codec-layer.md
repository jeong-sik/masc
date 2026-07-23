---
rfc: "0140"
title: "Dashboard wire codec for source observations"
status: Implemented
created: 2026-05-19
updated: 2026-07-13
author: vincent
implementation_prs: [16700]
---

# RFC-0140 — Dashboard wire codec for source observations

The dashboard decodes each backend closed type once and renders its source
meaning. Unknown values produce an explicit decode error. Codecs do not derive
risk, blocker, attention, automatic pause, operator action, or product policy.

Gate mode/request state, Keeper lifecycle, turn observations, and Task/Goal
states remain separate typed domains; a codec cannot promote one into another.
