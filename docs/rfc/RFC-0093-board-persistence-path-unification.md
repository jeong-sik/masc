---
rfc: "0093"
title: "Board persistence identity and atomic snapshot"
status: Implemented
created: 2026-05-17
updated: 2026-07-13
author: vincent
implementation_prs: [15711]
---

# RFC-0093 — Board persistence identity and atomic snapshot

`board_posts.jsonl` is an atomic current-state snapshot keyed by typed post id.
Create, Edit, Comment, Like, Unlike, and Emoji mutations preserve exact ids and
write through one explicit persistence result. A reader never chooses between
duplicate rows or silently repairs content.

Content similarity, author/status class, elapsed time, vote count, and repeated
text are not deduplication or write authority. Existing corrupt duplicate-id
data is reported as a typed migration error and repaired only by an explicit
operator migration, never an automatic on-load flag.
