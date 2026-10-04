# Exact activity: configuration, admission and readout

This unit adds `enabled` to Exact declarations and their immutable registry,
refuses new acquisitions when off, and preserves the previous acquired handles.
Existing Required lanes cannot be disabled. It updates the read-only TUI/Web
contract; dedicated toggle/save UI remains the next unit.

During source review, the Librarian JEV NoChange shortcut was found to bypass
admission. The response acquires candidates before registration/preflight and
passes that acquisition into full generation fallback. Off before entry does
not judge or acknowledge consumption. Native tests cover this case and toggling
off during preflight for both NoChange and generation. The TUI animation now uses
observed running count, including off lanes with accepted work still finishing.

Executed checks:

- OCaml 5.5.1 parsing: 41 changed ML/MLI files. This is not native typechecking.
- Isolated actual inventory decoder/display plus production exact decoder/type
  excerpts: 14 tests. `check-inventory.py` copies named files/blocks into a scratch
  directory and uses namespace aliases; provenance lists every hash and command.
  Run from the checkout with `opam exec --switch=5.5.1 -- python3
  docs/evidence/2026-10-04-exact-lane-activity/check-inventory.py`.
- Four affected Web suites: 38 tests; TypeScript and changed TS ESLint pass.
- [Actual Status/inventory browser readout](../../../dashboard/evidence/2026-10-04-exact-lane-activity/):
  five synthetic HTTP checks, zero mutations/page errors/unexpected API routes,
  and two screenshots. These are supplied on/off readings, not a configuration
  save or model execution. An initial invocation used the repository directory
  rather than `dashboard`; the corrected invocation produced the retained log.

Native parser/materialization, registry transaction, JEV admission, Verifier and
projection tests were authored/updated, but were not executed. Native backend,
complete TUI/PTY, model calls, CI, integration and deployment remain unverified.
No local Dune build was run. `checks.json` identifies source/harness hashes and
the separate evidence scopes. Existing JS results remain applicable after the
later OCaml-only review response; the OCaml parser was rerun for those files.
