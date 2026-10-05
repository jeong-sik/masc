# IDE CodeLens informational labels (weekly audit U5)

Parent PR [#41042](https://github.com/jeong-sik/masc/pull/41042) was open at
`7384d0168833dbea38664ab079f64960b9e31247`, with direct
base `fix/audit-ide-document-uri-20261004` at
`e4476abcd9397fef20aca008b968d1688e20e919`. The captured
[parent identity](parent-pr.json) records the REST response's absent `stack`
field, which the repository's scope reader normalizes to `null`, and the direct
base relationship. This evidence makes no merge-scope or approval claim.
That parent still displayed CodeLens titles with `cursor:pointer` and no
activation handler; its inlay-hint change did not fix U5.

The only product change removes that pointer cursor and adds the title
`읽기 전용 정보 · 실행할 수 없음`. Language-server titles remain plain text.
The server's `workspace/executeCommand` classification remains
`Deny_write_adjacent`; no command request, navigation or write authority was added.

The focused CodeMirror regression [fails on the parent](tests-before.txt) because
the rendered cursor is `pointer`. On the candidate, the complete LSP client suite
[passes all 44 tests](tests-after.txt), including the 43 existing tests. Scoped
ESLint and `git diff --check` passed. No full dashboard build or native build ran.

The [Chromium result](codelens-browser-result.json) and
[screenshot](codelens-source-fixture.png) come from a real CodeMirror editor with
the MASC LSP extension and read-only document filter. The language-server replies
are synthetic WebSocket fixtures. Both titles render with cursor `auto`, the
read-only tooltip, no button/link semantics and no keyboard focus stop. Actual
hover, click, Enter, Space and Tab leave the source unchanged and send no
`workspace/executeCommand`. There are no page errors.

`checkout_head` in that result is the parent checkout before the candidate commit;
the candidate source files are identified by their recorded SHA-256 values.
The result was captured with a fresh fixture Vite process. It is not an installed
dashboard, real language-server or production execution result.

Reproduce the focused frontend suite:

```sh
pnpm --dir dashboard install --frozen-lockfile
pnpm --dir dashboard test src/components/ide/ide-lsp-client.test.ts
```

Reproduce the browser fixture from the repository root, using an unused port:

```sh
cp docs/evidence/2026-10-04-ide-codelens-audit/codelens-fixture.html dashboard/audit-codelens-preview.html
cp docs/evidence/2026-10-04-ide-codelens-audit/codelens-fixture.ts dashboard/scripts/audit-codelens-preview.ts
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:9 pnpm --dir dashboard exec vite --host 127.0.0.1 --port 5187 --strictPort
# In another terminal:
python3 docs/evidence/2026-10-04-ide-codelens-audit/codelens-browser.py --repo . --url http://127.0.0.1:5187/dashboard/audit-codelens-preview.html --output-dir /tmp/ide-codelens-browser
```

Stop that fixture Vite process and remove the two copied preview files afterward.
The browser fixture intercepts API requests and supplies its own WebSocket.
