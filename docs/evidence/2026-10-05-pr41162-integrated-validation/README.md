# Integrated Exact activity validation

Remote repair baseline: `8b36ed906441270a673ab40aa7bcb50fcf514e0e`.
Latest integrated parent #41161: `c2e74cc3318a666d461164d23fcbec9089854069`.

The response carries enabled through preset capture, strict JSON loading,
comparison, comment-preserving TOML restoration and autosaves. Both activity
directions with unchanged candidates restore correctly. Disabled optional
lanes retain candidate syntax while skipping live runtime/CLI/deadline admission;
blank, duplicate and Required-off checks remain. Acquired Verifier candidates
carry their CLI/API kind through replacement fences and fallback rather than
consulting a replacement declaration. Explicit overrides remain separate.

Actual native integration exposed a missing local Result.bind and missing
Toml_line_editor test dependencies; both were fixed. The new preset restore test
then exposed an incomplete fixture: providers/models existed but no explicit
provider-model bindings. Those bindings were added only to the new fixture,
with all restore/autosave/comment/candidate assertions preserved.

Focused native results (313 tests total):

| Executable | Passed |
| --- | ---: |
| test_runtime_config_validity | 147 |
| test_prompt_preset | 15 |
| test_exact_output_catalog_precedence | 14 |
| test_verifier_exact_lane | 22 |
| test_keeper_librarian_absorb_gate | 45 |
| test_keeper_librarian_preflight | 17 |
| test_keeper_librarian_capacity_callback | 18 |
| test_keeper_librarian_exact_lane_preference | 6 |
| test_server_standalone_lane_projection | 15 |
| test_tui_lane_inventory | 14 |

All 27 changed test consumers compiled on the final integrated parent.
The core four executables were then rerun with their binary hashes recorded
to bind their results to this integration; earlier runs remain historical.
The later absorb fixture correction was rebuilt and all45 cases executed.
Its inherited record-cardinality/output-order issues and exact logs are in
[the absorb fixture record](../2026-10-05-pr41162-absorb-fixture/README.md).
The first absorb invocation used the wrong cwd and could not open its golden
fixture; correcting cwd exposed the real inherited assertion drift. These
failures are retained, not reported as product regression reproduction.

Commands: use `opam exec --switch=5.5.1 -- scripts/dune-local.sh build` with the
27 executable paths in build-targets.json. Run focused executables with
DUNE_SOURCEROOT set to the checkout; run absorb from test/ for its relative
fixtures. The final preset command executes test_prompt_preset.exe after the
fixture-only rebuild. No full dune runtest was run.

Web: dashboard standalone-lanes API, inventory API and inventory component
suites passed13 tests; whole-dashboard TypeScript and changed-file ESLint passed.
Commands: `pnpm test src/api/dashboard-standalone-lanes.test.ts src/api/lane-inventory.test.ts src/components/lane-inventory-panel.test.ts`,
`pnpm exec tsc --noEmit --pretty false`, and scoped `pnpm exec eslint`.

Independent source review covered the integrated product, interfaces and
regressions; root separately reviewed the later absorb fixture repair. Earlier
isolated/parser/Chromium artifacts remain historical. These are local native
fixtures and mocked-HTTP Web tests, not a new complete TUI/PTY, real-provider,
hosted CI, deployment or release result. No pre-repair behavioral RED for the
three original P2s is claimed; their corrected assertions were executed here.
Raw output is copied unchanged, including trailing blank lines.
