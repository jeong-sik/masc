# Keeper reading surface evidence

This slice continues #41685 and #41703. Keeper names lead the roster; repeated
Health tallies, the wall clock, extra table rules and the selected OPERATIONS
footer no longer compete with the list. Fleet warnings, connection identity,
selection, unread observations and action outcomes remain.

Composite lifecycle, turn, idle and outcome readings now live in Info's Runtime
Stats as separate fields. The existing runtime target remains beside them.
Info owns their entry/manual/periodic refresh; a failed refresh labels retained
values stale. Labels are muted and narrower, and an overlong label gets its own
row rather than being elided.

## Source projection

`python3 docs/evidence/tui-keepers-reading-20261007/project-fields.py` passed.
It extracts the actual header, column allocator, field renderer and SGR-strip
functions and interprets them with the actual message-layout module. The
isolated `Ansi` module supplies only the reset sequence used by the local field
helper. `fields.json` records 24 field projections at 40, 76 and 116 content
cells, with intact labels/values (including Korean and long runtime identities)
and no row overflow. This is not a compiled application or terminal capture.

## Direct consumers and remaining execution

| Changed interface | Consumer | Verification |
| --- | --- | --- |
| Keeper list order and chrome | selection bands, pointer rows, viewport window | Updated primary-list/region/open-turn/roster-window scenarios; PTY run pending |
| Wrapped Info labels and execution fields | counted detail rows, scroll, metadata tails | Source projection passed; metadata-wrap and composite navigation PTY pending |
| Info lane read ownership | entry, manual refresh, periodic updates, stale recovery | Info refresh scenario pending |

Independent source review found two P2 issues: the relocated fields needed
Info-owned refresh, and the expanded overflow fixture initially waited for an
offscreen row. Review-response changes address both; final rereview status is
recorded in the PR. No local Dune build, CI dispatch or installed binary change
was performed for this slice.

The [consistency ledger](../../design/tui/CONSISTENCY-PROGRESS.md) keeps broader
surface work and actual executable validation open.
