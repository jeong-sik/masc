# Installed LSP document acceptance — 851f412

The actual installed IDE now sends the full source in didOpen, sends corrected source in didChange on the same native WebSocket, and displays the resulting real ocamllsp diagnostics. The final accepted receipt has `probe_passed: true`, no page/HTTP/assertion errors, and `fixture_restored: true`.

Initial source `let value =\n` has three native diagnostics: missing project configuration, a typed hole, and a syntax error. Corrected source `let value = 1\n` removes the hole and syntax error; the project-configuration diagnostic remains. UI count changes from `3 diagnostics` to `1 reported · version unconfirmed`; visible gutter markers change from two to one. Exact native diagnostic arrays match the independently captured [direct-process reference](../2026-09-13-installed-lsp-dune-resolution/toolchain-path-buffer-change/diagnostics-reference.json). All arrays, source hashes, version1→2 frames, displayed marker titles, manifest-checked assets and screenshots are preserved in `accepted/receipt.json`.

The language server does not identify the document version on its diagnostic notifications. The UI honestly retains `version unconfirmed`; this observation does not establish provider version attestation. The remaining configuration error is not hidden. No local Dune build ran. This proves this owned fixture's full installed browser/proxy/server path and manual same-file reselection, not automatic file watching, Keeper LSP tool use, every language, or general Dashboard connectivity. Unrelated Dashboard WebSockets are intentionally blocked by the probe.

## Environment correction and earlier failures

The first installed attempt failed because ocamllsp selected a non-executable Dune wrapper and raised EACCES. A direct native control reproduced that failure without the proxy. Prepending the existing directory resolved from the actual ocamllsp executable selected its executable toolchain Dune. The wrapper was untouched. The owned server was restarted with that PATH and portable LibreOffice available; source remains `851f412a88f4d5bf290dfa67ac60c4b78bb3ebb1`, binary SHA `41a75acff6d190e767cebee3b53c371ed643293a41e1f1b5d93a6c5ab88c180d`, PID90054/counter158. All 352 canonical scoped files were unchanged again.

The first reference-based browser probe then incorrectly expected the initial status to say `reported`; the actual initial state says `diagnostics`. That failed attempt is preserved in `probe-label-failure/`. The probe now accepts either exact numeric label, verifies full diagnostic arrays against the direct control, and still requires version-unconfirmed display after the unversioned updated reply. The default probe mode retains its original empty-diagnostic requirement; only explicit reference mode covers the known unconfigured project fixture. Final desktop and mobile screenshots were captured, and root inspected the desktop outcome.

## Reproduce

Use `scripts/verify-installed-ide-lsp.mjs` with the installed prefix/source/base URL, a fresh output directory, private token file, owned fixture descriptor, and `--diagnostics-reference` pointing to the archived direct-process reference. It restores the owned source after browser cleanup. Do not normalize or replace raw protocol evidence with a success summary.
