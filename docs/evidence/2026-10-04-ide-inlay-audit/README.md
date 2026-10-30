# IDE inlay hint rendering (audit U3/U4)

Product source tested and independently reviewed:
`63c4b772166e3f064e09ab2d12d293005e8c368a`.
Parent: `e4476abcd9397fef20aca008b968d1688e20e919` (#41035).

Each hint is positioned using its own character offset. Stable ordering uses
its effective clamped position, so hints at the same rendered position retain
server response order, including out-of-range offsets clamped to line end.
Standard composite label parts are rendered as text, with whole-hint and
per-part string/MarkupContent tooltips. Native title attributes display markup
source as plain text. Command execution, navigation and lazy hint resolution
are not implemented by this change.

Seven new regressions failed before the initial fix; the complete LSP client
suite passes 43 tests after the final fix. The final test also covers the
review-discovered effective-position tie and reconnect tooltip update without
clearing the document's hint field. Run from the repository root:

```sh
pnpm --dir dashboard test src/components/ide/ide-lsp-client.test.ts
```

Scoped ESLint passed. Full dashboard TypeScript checking fails with the same
three diagnostics in `src/api/dashboard-runtime-context.test.ts` at both the
parent and this branch. Both logs are preserved; this is not a whole-dashboard
typecheck pass.

The Chromium fixture uses real CodeMirror and the MASC LSP extension with a
synthetic WebSocket responder. It asserts six DOM labels and positions,
whole/part title attributes, and no page errors. It does not connect a real
language server, installed application or production runtime.

To reproduce the browser fixture (requires Python Playwright with Chromium):

```sh
cp docs/evidence/2026-10-04-ide-inlay-audit/ide-inlay-fixture.html dashboard/audit-inlay-preview.html
cp docs/evidence/2026-10-04-ide-inlay-audit/ide-inlay-fixture.ts dashboard/scripts/audit-inlay-preview.ts
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:9 pnpm --dir dashboard exec vite --host 127.0.0.1 --port 5181 --strictPort
# In a second terminal, from the repository root:
python3 docs/evidence/2026-10-04-ide-inlay-audit/ide-inlay-browser.py --repo .
```

The fixture intercepts API requests and supplies its own WebSocket. Stop the
fixture Vite process and remove the two copied preview files after running.

Protocol sources:
- https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.17/types/position.md
- https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.17/language/inlayHint.md

Independent source review history is preserved in `ide-inlay-source-review.json`.
It is not a GitHub approval or cross-model review.
