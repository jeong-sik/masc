---
rfc: "0119"
title: "Withdraw lifecycle projection mapping hierarchy"
status: Withdrawn
created: 2026-05-17
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0072", "0113", "0114", "0115", "0116", "0117", "0118"]
implementation_prs: [15967]
---

# RFC-0119: Withdraw lifecycle projection mapping hierarchy

## Decision

Withdraw the guard-marker system for keeping multiple collapsed lifecycle
vocabularies synchronized.

The drift was caused by duplicating Keeper lifecycle truth into several
observer-specific phase sets. The fix is to remove those policy projections,
not to add another parser and lint hierarchy. Observers consume typed source
events and may derive presentation-only views that never authorize behavior.

Historical implementation remains available in Git and is not current runtime
authority.
