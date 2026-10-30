# IDE document URI preservation (audit U2)

Product source tested: `fe24a86faa168a49be1e76043b56bb87fb526e15`.

Literal `#`, `?`, `%`, spaces and Korean path characters are escaped in the
URI path without becoming fragments, queries or preexisting escape sequences.
Four regression cases failed before the fix. The complete LSP client test file
passes 36 tests after the fix:

```sh
pnpm --dir dashboard test src/components/ide/ide-lsp-client.test.ts
```

The tests use the actual LspConnection with a mock WebSocket and inspect open,
change, codeLens, inlayHint, hover and close messages. WHATWG URL parsing and
percent decoding recover the original absolute path.

The Chromium fixture renders the real CodeMirror editor and MASC LSP extension
with a synthetic WebSocket responder. Its workspace and document both contain
special characters. The responder rejects changed paths; the fixture confirmed
correct URI round-trip, a diagnostic DOM marker, hover traffic and no page
errors. See the JSON and screenshot. This is not a real language-server,
installed application, production or full CI result. Test logs preserve the
observed failures/pass with trailing whitespace normalized.
