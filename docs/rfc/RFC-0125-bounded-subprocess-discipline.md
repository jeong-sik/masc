---
rfc: "0125"
title: "Withdraw Keeper watchdog and force-release discipline"
status: Withdrawn
created: 2026-05-17
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0072", "0097", "0101", "0106", "0107"]
implementation_prs: [15940, 15958, 15964, 15973]
---

# RFC-0125: Withdraw Keeper watchdog and force-release discipline

## Decision

Withdraw the Keeper-level watchdog, stale-turn timeout inference, semaphore
force-release workaround, and soak-window gating proposed by this RFC.

The watchdog measured elapsed lifetime/progress and converted it into Keeper
restart authority. `force_release_holder_for` then mutated concurrency state
without proving that the underlying work had ended. Both are heuristic
lifecycle controls and can corrupt lane ownership.

Concrete subprocess and socket operations still require their own structured
resource scope, cancellation propagation, and typed timeout/error result. That
objective boundary belongs to the process/transport implementation and does not
pause, restart, or terminate a Keeper. Long-running work should be represented
as a Job and wake the originating lane when it completes.

Historical implementation PRs remain available in Git and are not current
runtime authority.
