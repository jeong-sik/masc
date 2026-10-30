# Installed IDE LSP baseline (2026-09-13)

The installed full IDE displays the real invalid OCaml file (`let value =\n`) but sends `textDocument/didOpen` with an empty `text` at version 1. This reproduces the document-continuity bug through the installed dashboard, actual workspace HTTP API, native browser WebSocket, and installed MASC LSP proxy. The baseline has zero gutter diagnostic markers and no selected-file LSP status chip. It is not acceptance of the new LSP feature.

`receipt.json` records `baseline_observed: true`, `probe_passed: false`, and empty page errors and probe failures. The browser screenshot was inspected. Observed binary commit is `4324764e959a5ff8b265b292e5bab9f68e550313`, executable SHA256 `a38ff7f2e6ecbd9efe6dcfbb2469d67e56e837f3cad7eba0fa2f7eed6571643a`; every observed dashboard asset is checked against that installed release manifest. Source feature PR #35605 and subsequent integration candidates are separate from this old installed baseline.

The owned detached worktree is `/private/tmp/masc-installed-ide-lsp-fixture-20260913`, source HEAD `83f31140dbce4908ce803c65081cd0f4d80a1454`. Its dedicated `lsp-acceptance-sample.ml` and ownership descriptor are the only fixture additions. The registered repository is `lsp-acceptance-probe-20260913`, has `auto_sync: false` and no Keepers. Root registered that exact local worktree after checking the repository handler; the probe itself does not register or sync repositories. Baseline mode performs no source changes. No original repository, Goal, Task or Keeper was changed by this probe.

## Probe and acceptance boundary

`scripts/verify-installed-ide-lsp.mjs` reads an existing private operator token without writing it into evidence. Requests use the real installed HTTP responses and browser-native WebSocket connection; no asset/source responses or LSP server messages are synthesized. It uses passive Playwright [WebSocket frame events](https://playwright.dev/docs/api/class-websocket) to inspect actual protocol messages. Unrelated dashboard WebSockets and mutation requests are blocked, so the visible general dashboard reconnecting state is imposed by the probe and is outside its LSP acceptance claim.

For a newly installed candidate, run from the checkout with Playwright available:

```sh
node scripts/verify-installed-ide-lsp.mjs \
  "$INSTALLED_PREFIX" "$EXPECTED_COMMIT" "$BASE_URL" \
  "$FRESH_OUTPUT_DIR" "$TOKEN_FILE" "$FIXTURE_JSON"
```

Use `--baseline` only to observe an older installation: it can never set `probe_passed` true. The prepared local fixture descriptor is `/tmp/masc-installed-ide-lsp-preparation-20260913/fixture.json`.

Acceptance requires exact installed binary and asset identity, complete real source/API agreement, actual full-text `didOpen`, server diagnostics and gutter markers, then a source change confined to the owned file. Reselecting the same filtered explorer row invokes the real file API. The existing editor connection must issue a monotonically newer `didChange`; an actual later empty server diagnostic report must match that URI, the gutter must clear, and an unversioned server report must visibly remain `version unconfirmed`. Finally the file is restored, and late observation/restoration errors override success. This is a same-file manual refresh scenario, not automatic file watching or autonomous Keeper action.

## Preserved failed probe attempts

- `failed-local-network-receipt.json`: HTTP `route.fetch` + `fulfill` changed the browser document network context, yielding `ERR_BLOCKED_BY_LOCAL_NETWORK_ACCESS_CHECKS` on the real LSP WebSocket. The final probe uses native HTTP `route.continue` and passive response inspection; LSP is also observed passively. A direct browser connection and the corrected installed full IDE both completed the real handshake.
- `failed-tree-selection-receipt.json`: a click during dynamic expansion of the large repository explorer selected `lib/error_event_type.mli` instead of the intended fixture. The probe rejected the wrong URI and preserved the failure. The final probe filters by the exact fixture filename, waits for one visible matching row, then clicks it and verifies selected source identity.

Other early attempts remain under `/tmp/masc-installed-ide-lsp-*-baseline-20260913`; none is counted as feature acceptance. The final baseline in this directory was captured before the review-only finalization adjustment that defers asset verification and rechecks late failures immediately before writing the receipt. That adjustment passed Node syntax and branch inspection; the installed baseline was not needlessly rerun. The strict source-update acceptance remains unrun until the new integration candidate is installed.
