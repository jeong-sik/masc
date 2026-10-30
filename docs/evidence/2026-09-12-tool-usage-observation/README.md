# Tool usage observation scope

The source audit used runtime commit
`53203f998a2df9f6149e1c033d5602836a8d7066` and its actual dashboard tools response.
An allowlisted JSON projection and source-response digest are in
`dashboard/src/components/tools/fixtures/tool-usage-53203.json`.

The observed counts reconcile as follows:

- Inventory: 171 names, including 13 Keeper public-name projections beyond the
  158 canonical catalog names.
- Canonical visible catalog: 103 names = 26 observed + 77 without an observed
  call in the metrics snapshot.
- All observed names: 50 = 26 visible + 24 hidden; none outside the catalog in
  this snapshot. The projection also supports retained names outside the current
  catalog, without classifying them as hidden.
- Metrics: 775 calls. The independent non-public call log has 645 retained rows.
- The existing direct-handler registration count is 21. Its aggregation remains
  unchanged; the misleading operator summary is removed.

`browser.png` and `browser.json` are a headless Chromium rendering of the real
ToolMetrics component through local Vite, using the allowlisted actual counts and
the proposed API projection. They verify the metrics component, not a deployed
runtime or the full Tools page. No page errors occurred. The revised source note
does not claim SQLite hydration or persistence succeeded: this response has no
such status. A missing call in this snapshot is not proof of lifetime non-use.

Validation: targeted frontend tests passed 212 cases; TypeScript and OCaml
parse-only checks passed. The final wording change passed its rendering test and
browser assertions again. Native aggregation tests are dispatched to CI; no
local Dune build or live runtime/configuration change was performed.
