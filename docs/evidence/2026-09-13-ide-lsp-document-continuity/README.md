# Selected-file LSP document continuity

The editor now sends the actual CodeMirror source on `didOpen`, followed by monotonically versioned full `didChange` notifications when the Keeper/store updates that read-only buffer. A diagnostic result is scoped to the connection, workspace and document generation. Old explicit versions and old sockets cannot publish into the selected document. Workspace changes require a fresh document snapshot instead of opening old workspace content under the new root. Source snapshots retain their workspace scope, so even a batched same-path switch recreates the editor without depending on a transient null render.

The selected-file status distinguishes connecting, disconnected, unavailable, unsupported, request failure, confirmed diagnostic counts and unversioned server reports. This reports browser editor analysis; it does not claim the Keeper used an LSP tool. Existing current Task/Goal, work history and code-query tools remain separate surfaces.

## Measured evidence

- Five Vitest suites (111 tests) passed, covering client lifecycle, actual CM buffer updates, selected-file status, and workspace stores. Captured output is in `vitest.txt` (trailing blank lines normalized).
- Whole Dashboard `tsc --noEmit` and selected-file ESLint passed. No Dune or Vite production build was performed locally.
- `scripts/lsp-editor-browser-probe.mjs` ran Chromium against Vite's development transformer and the real installed `ocamllsp` through a test-only JSON-RPC adapter. Source file digests are in `source-sha256.json`.
- The actual invalid source `let value =\n` produced two diagnostics. Updating CM to `let value = 1\n` emitted `didChange` version 2, and ocamllsp reported an empty diagnostic list. `receipt.json`, `protocol.json`, and both PNG captures preserve those observations. Actual visible diagnostic markers changed from 2 to 0.
- Ocamllsp omits the optional diagnostic version and rejects pull diagnostics, even with `publishDiagnostics.versionSupport=true`. After the source changes, its reports remain visible with **version unconfirmed**; unsupported pull does not erase those reports.
- `first-probe-failure.json` preserves the first browser harness failure: its middleware was registered after Vite's HTML fallback, so the fixture was not reached. The probe now installs its route through `configureServer` before the fallback. `spacer-probe-failure.json` records a later fixture selector matching CodeMirror's hidden spacer instead of a diagnostic; the final probe selects visible diagnostic markers with nonempty titles.

This is source-client and real-language-server browser evidence. The adapter is not the installed MASC WebSocket proxy, the page is not the full installed IDE shell, and the update is a store-equivalent CM transaction, not an autonomous Keeper execution.

## Reproduce

Use the worktree's Dashboard dependencies and an existing `ocamllsp` executable:

```sh
node scripts/lsp-editor-browser-probe.mjs dashboard ocamllsp /tmp/lsp-browser-evidence
```

The output directory owns the synthetic workspace and Vite cache. The probe shuts down its own browser, language server and development server. It does not build MASC, install dependencies, or modify a user workspace.

Protocol references: [document synchronization](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_synchronization), [publish diagnostics](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_publishDiagnostics).

## Native protocol comparison

The root-owned `scripts/lsp-native-document-probe.py` also exercised the actual ocamllsp executable directly. `native-version-support` and `native-baseline` both pass: invalid source produces two errors and the corrected source produces none. Both configurations omit the optional diagnostic version; pull diagnostics returns -32603, Request not supported yet. `native-first-failure` preserves the initial harness error: shutdown sent null params, which the server rejected; the successful probe omits params for shutdown and exit. These probes own synthetic files and do not establish installed IDE or Keeper behavior.

The MASC proxy now advertises publishDiagnostics.versionSupport=true during initialize. This requests versioned reports; it does not assume every server supplies them. OCaml parse-only verification passed.

In the integration candidate, the first native stderr capture has only trailing blank lines normalized for the repository whitespace check. Its messages are unchanged; the byte-original remains in source commit83f31140db.
