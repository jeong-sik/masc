---
title: Withdraw Keeper terminal-reason hierarchy
rfc: 0042
status: Withdrawn
created: 2026-05-08
updated: 2026-07-13
implementation_prs: []
---

# RFC-0042: Withdraw Keeper terminal-reason hierarchy

The closed terminal taxonomy became a policy layer: runtime observations were
promoted into operator dispositions, automatic pauses, and terminal outcomes.
That coupling is removed.

A Keeper remains active after an explicit tool, provider, persistence, or Gate
failure and may choose another activity. Only an explicit operator
pause/resume/stop or a durable Dead tombstone controls Keeper lifecycle.
Failures remain typed observations at their native boundary and are never
converted into a global severity or terminal hierarchy.

This document is historical only and defines no compatibility surface.
