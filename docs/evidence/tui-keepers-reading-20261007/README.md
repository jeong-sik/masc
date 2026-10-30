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

## Direct consumers and remaining execution

| Changed interface | Consumer | Verification |
| --- | --- | --- |
| Keeper list order and chrome | selection bands, pointer rows, viewport window | Manual check in a rebuilt TUI pending |
| Wrapped Info labels and execution fields | counted detail rows, scroll, metadata tails | Manual check in a rebuilt TUI pending |
| Info lane read ownership | entry, manual refresh, periodic updates, stale recovery | `test_tui_server_identity_refresh` covers the queued reread folding into resume; live refresh check pending |

Tests do not pin screen wording, widths or row order (`docs/constitution.xml`
execution protocol), so layout is checked by hand.

Independent source review found two P2 issues: the relocated fields needed
Info-owned refresh, and the expanded overflow fixture initially waited for an
offscreen row. Review-response changes address both; final rereview status is
recorded in the PR. The stack is type-checked with `dune build --root . @check`;
the PR comments name the run and the head it covered. `source-checks.json`
records the parser check and SHA-256 of `bin/masc_tui.ml` and
`bin/masc_tui_render.ml` in this layer's tree.

The [consistency ledger](../../design/tui/CONSISTENCY-PROGRESS.md) keeps broader
surface work and actual executable validation open.
