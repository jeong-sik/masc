# #41135 parent integration

Published #41135 `cedab0d0e55ab5a0e928ef555cec5d637d8202eb` cleanly merged
published #41131 `bd414e75e63dc817d9e8aa2adab4fb06c8af7852`.
No independent product edits were made. The incoming stale-removal PTY fixture
needed one integration field, `enabled: True`, because this branch requires the
explicit activity Boolean when decoding declaration rows. This is a source-
confirmed schema mismatch; no runtime RED is claimed for the missing field.

Focused validation on the integrated candidate:

- `opam exec --switch=5.5.1 -- scripts/dune-local.sh build bin/masc_tui.exe test/test_server_lane_inventory.exe`: PASS.
- `_build/default/test/test_server_lane_inventory.exe`: 5 PASS, including actual H2 admin/anonymous/Worker requests.
- `PYTHONPATH=test python3` importing `test_tui_lane_operator_pty.stale_removal` and passing the absolute `_build/default/bin/masc_tui.exe`: PASS. This executes only the stale-removal scenario, proving no request for a mismatched revision and the exact worker request after matching-revision refresh.
- In `dashboard`, `pnpm test src/components/lane-declaration-editor.test.ts src/components/lane-addons-panel.test.ts`: 56 PASS in two suites; `pnpm exec tsc --noEmit --pretty false`: PASS.
- ESLint on the six incoming Web files: PASS. Ruff and Pyright on `test/test_tui_lane_operator_pty.py`: PASS, zero diagnostics.

The merged Addons interface, off-state display, and removal predicate were read
together. Skill withdrawal implementation/tests are unchanged from the
published child. Earlier native/PTY/browser evidence remains historical; no
full native suite, browser run, CI or release readiness is claimed here.
Raw logs are copied unchanged, including trailing whitespace/blank lines.
