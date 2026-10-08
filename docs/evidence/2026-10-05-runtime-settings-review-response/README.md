# Settings review response (#41160)

This is focused local component/API evidence on parent-unintegrated HEAD
`9607401db6a914b4241628c80a7724a48ae49ad0` plus the source files hashed in
`checks.json`. It is not native, browser, full-suite, CI, or deployed proof.

The actual raw-save API decoder regressions and mounted editor retry reproduced
three failures on the original production code (`known-refusal-red.log`). The
actual Settings/session commit producer reproduced the authority-switch loading
failure (`authority-refresh-red.log`). The initial authority test used an API
absent from this branch; its setup failure is retained separately and is not a
behavioral reproduction. The first two repaired-suite attempts exposed an invalid
success receipt in the new retry fixture (source/commit/skills revision mismatch).
The final fixture uses a consistent real wire receipt; assertions were retained.

Final focused Vitest: 165 tests in three suites passed. From `dashboard`, the
scope is `pnpm test src/api/dashboard-runtime-raw-save.test.ts
src/components/runtime-toml-editor.test.ts src/components/settings-surface.test.ts`.
`pnpm exec tsc --noEmit` passed. ESLint across the seven changed TypeScript files
returned two `no-nested-ternary` errors in dashboard-runtime.ts at lines 989 and
991. The HEAD stdin baseline has exactly the same diagnostics; there are no new
diagnostics. Raw JSON results are retained. Product diff whitespace check passed.

The rejection classifier uses actual POST /api/v1/runtime/config/raw structured
400 responses, not error text. Other statuses, malformed error bodies, and
reported effects remain uncertain. Server raw route validation and
Config_edit_failed responses precede visible replacement. Runtime atomic failure
after visible replacement returns a committed receipt; observed lock release
failure preserves the body receipt with warnings (runtime.ml
with_runtime_config_lock_using/save_config_text_if_current and
file_lock_eio.ml with_durable_lock_observed_with). No server contract was changed.

Authority replacement resets and reissues Settings snapshots; late former-owner
responses cannot overwrite the new authority. The regression holds the four
postcommit reads, replaces authority, and releases the old reads after the new
snapshot is rendered. No parent integration has been attempted in this response.
