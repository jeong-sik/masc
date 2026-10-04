# Local package discovery into the TUI installer

Parent: `cd2ce1628521d507dc7e438b4f44949e15b1d6a4` (#41204).

Add-ons `i` reads one folder in the connected workspace. Folder navigation,
package metadata and errors come from the catalog endpoint. The endpoint uses
the existing real manifest loader, in a system thread. Selection requests a
fresh package/image preview; the existing schema form creates a local draft,
and `s` explicitly submits it. Manual manifest input remains available with `p`.
Workspace replacement and request generations reject stale catalog responses.

## Executed

`DISCOVERY_OCAML_BIN=<OCaml 5.5.1 bin directory> python3
 docs/evidence/2026-10-05-tui-package-discovery/check-discovery.py`

- Actual complete catalog and package-browser modules compile/link with warnings
  32 and 69 enabled and warnings treated as errors.
- Four journeys execute filesystem discovery, bounded traversal by directory,
  invalid loader outcomes, symlink escape refusal, navigation, fresh-preview
  handoff, refresh identity and selection at the end of a long list.
- The installer separately typechecks against its exact source interfaces for
  the schema form and declaration owner. This is not a link/execution check.
- Changed OCaml files parse; Python scenario ASTs parse. See `syntax.json`.
- `check.txt` and `provenance.json` record commands, results and source hashes.

The focused executable uses a controlled manifest-loader callback. It does not
execute the real manifest parser, route, schema form, main TUI, terminal renderer,
worker, Docker, backend persistence, deployment or CI. The `Masc` file in its
scratch directory only aliases the complete actual catalog module; it contains
no behavior replacement.

## Authored, not executed

- `test_lane_addon_catalog.ml`: actual manifest parser supplies selectable title
  and revision; malformed TOML remains an issue.
- `test_tui_lane_addons.ml`: late/canceled catalog responses, failure recovery,
  catalog selection to fresh preview and existing schema/draft serialization.
- `test_tui_lane_operator_pty.py`: root folder to package to preview/schema,
  manual path entry, and exactly one explicit declaration save with no attach.

Native TUI/PTY and whole-server checks remain unverified under the repository's
no-local-Dune workflow. Web catalog/forms, Web package on/off, target navigation,
continuous application tracking, Goal work and main integration are separate
remaining units of the full Lane UX goal.
