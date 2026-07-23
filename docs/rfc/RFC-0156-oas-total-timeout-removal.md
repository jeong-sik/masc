---
name: RFC-0156
title: Withdraw MASC turn-budget timeout policy
status: Withdrawn
authors:
  - vincent.dev@kidsnote.com
created: 2026-05-22
updated: 2026-07-13
---

# RFC-0156 — Withdraw MASC turn-budget timeout policy

MASC no longer converts turn duration, token count, or total attempt time into
a Keeper lifecycle or admission decision. Those values remain observable.

Transport and provider calls may still return explicit protocol-level timeout
or cancellation results through OAS. Such a result is local to the call and
does not pause the Keeper or prevent another configured runtime attempt. No
legacy timeout override or compatibility clamp from this RFC remains.
