# Stored workspace memory proposals in Memory Lab

The panel next to the Keeper memory inventory reads the authenticated
`/api/v1/dashboard/workspace-memory-proposals` endpoint. It displays the stored
model proposals with their attributed shared statements, unresolved conflicts,
excluded sources, and missing/unavailable collection gaps. Source buttons reveal
the corresponding captured source and snapshot metadata, including invalidation
paths. The full envelope remains available as keyboard-focusable JSON.

The panel states that factual correctness has not been separately verified. It
does not add an approval workflow or claim Keeper recall already uses these
proposals. Loading, HTTP/contract failure, and a successfully empty store are
separate states. Refresh preserves an explicitly selected proposal ID and ignores
late responses from superseded requests.

Validation: nine focused component/API scenarios passed using Vitest. These
exercise evidence disclosure, collection gaps, request failure and retry,
selection across refresh, stale-response isolation, and rejection of invalid
contracts or broken source identity/coverage. No local build was run. CI artifact
browser verification and deployed endpoint rendering are still pending.
