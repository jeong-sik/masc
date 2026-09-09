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
contracts or broken source identity/coverage. No local build was run.

Browser verification passed against CI run 34390302584, artifact 10119393135,
PR source e7649f91b72661655a4e785af1dbd8f37f30cae8. The harness verified every
asset hash in preview-provenance.json before loading it, then rendered the saved
Qwen proposal plus explicit synthetic selection/error fixtures over the live
backend. It checked exact source/snapshot disclosure, keyboard focus, selection
refresh and fallback, failure/retry/empty states. Mobile horizontal overflow was
false and no page errors were observed. Screenshots were visually inspected.
`browser/receipt.json` and screenshots preserve this observation.

The model proposal fixture is synthetic-task output, not production Keeper
memory. HTTP writes and WebSockets were blocked by the harness. The live page's
build warning reflects the deliberately different CI assets and live server.
Deployed proposal endpoint rendering and actual Keeper reuse remain pending.
