# Item integration evidence at af8d806

Tested source: `af8d806ec1c4f12a368189e78d013ac30d3a2296`.
These files retain evidence for that parent source. Adding this evidence to a
later HTTP harness commit does not prove the later code.

- [Test run 36662886238](https://github.com/jeong-sik/masc/actions/runs/36662886238): completed success. Native suites: dashboard HTTP 136, Goal tools 25, Goal store 37, Goal timeline 17, schema size 4, portrait HTTP 15, purchase 8, ledger 10, TUI control 54. Total **306 native cases**. Item/portrait PTY 6 scenarios and Candle currency PTY 4 scenarios passed. The compressed raw suite log retains expected negative-test errors as well as the actual successful suite outcomes.
- [Dashboard run 36662890803](https://github.com/jeong-sik/masc/actions/runs/36662890803): completed success. Seven Chromium screenshots and their original manifest prove production Item component transitions under controlled synthetic account/roster revisions. Browser version 149.0.7827.55. Screenshot hashes were independently verified after download.
- `tui-manifest.json`, six text frames and the archived PTY streams come from the real TUI executable driven by synthetic account HTTP responses. Binary SHA-256: `5fa0b142ce2a3b23d73231fdfdae5c29a9f5841e8f0a43b69724abf5c0b2964c`. The fixture is 100 columns with 24 Item rows.

The browser capture uses a component fixture and the PTY uses a synthetic
server. Neither proves an installed production server, real paid purchase,
model decision or operational rollout. The separate Item HTTP acceptance
workflow is intended to exercise the real native server and MCP ledger;
its execution is still pending when this evidence is recorded.

`SHA256SUMS` covers retained evidence files, excluding itself.
