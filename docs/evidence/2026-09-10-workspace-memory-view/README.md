# Workspace memory view

The Lab memory page now displays all Keeper claims alongside existing health
statistics, with owner filtering, store revisions and saved times. Conflicting
claims remain visible. Missing stores, unavailable stores, discovery failure and
HTTP/decode errors have distinct presentations. Full stored metadata is available
under a keyboard-focusable disclosure; it is labelled as the current snapshot
and latest changes rather than the complete historical journal.

The page explicitly states that source files were not revalidated and stores
were observed individually. It does not claim a synthesized shared memory or an
active curator lane.

Focused component validation: 11 tests across the workspace context and Lab
suites pass, including stale response isolation, failed read retry and selected
Keeper disappearance. No local build. CI-built browser verification remains
pending. Run `scripts/verify-workspace-memory-preview.mjs` with a downloaded CI
preview, its PR head, a read-only backend URL and an evidence output directory.
The browser scenario uses synthetic workspace-memory HTTP data while rendering
the real Lab page, and blocks HTTP writes and WebSockets.
