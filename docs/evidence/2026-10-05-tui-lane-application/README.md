# TUI Lane application observations

Base: PR #41211, `8f5b84e793edf7e15e54cf5eadc596ce4c2ab437`.

- Actual application, declaration and TOML editor sources compiled together in
  an owned temporary directory with installed OCaml 5.5.0, Yojson, Otoml and
  Alcotest. Five operator scenarios passed; source hashes and command are in
  `pure-check.json`, log in `pure-tests.txt.gz`. No facade or mock module replaces
  those production modules. The project pins 5.5.1; this is not that full build.
- Changed OCaml sources parsed successfully (`syntax.json`). Three modified
  Python PTY fixtures were syntax-compiled in a temporary directory only.
- The Add-ons integration regression is authored and parsed: it exercises
  renderer/editor/receipt preservation with independent application results.
  It has not been typechecked or executed in the full TUI dependency graph.
- The PTY fixtures now carry the required application/source identity fields.
  These fixture scenarios were not run. No native terminal, actual HTTP server,
  worker, Web, CI, main integration or deployment execution is claimed.

The independently owned observation updates only application state. Existing
workspace-scoped transport retires cross-workspace replies; per-read tickets and
explicit-action generations prevent older replies from overwriting current reads.
Saved file identity, draft text and observed application remain separate.
