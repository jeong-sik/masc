# Workspace memory view

The Lab memory page now displays all Keeper claims alongside existing health
statistics, with owner filtering, store revisions and saved times. Conflicting
claims remain visible. Missing stores, unavailable stores, discovery failure and
HTTP/decode errors have distinct presentations. Full stored metadata is available
under a keyboard-focusable disclosure; it is labelled as the current snapshot
and latest changes rather than the complete historical journal.

The page explicitly states that source files were not revalidated and stores
were observed individually. It does not claim a synthesized shared memory or an
active curator lane.

Focused component validation: 11 tests across the workspace context and Lab
suites pass, including stale response isolation, failed read retry and selected
Keeper disappearance. No local build. CI-built browser verification is recorded
below. Run `scripts/verify-workspace-memory-preview.mjs` with a downloaded CI
preview, its PR head and an evidence output directory. The browser scenario uses
an isolated synthetic workspace-memory HTTP fixture while rendering the real Lab
page. Browser-context interception blocks every request outside the preview
assets and fixture, as well as HTTP writes and WebSockets; popups are closed.

## Browser evidence

Passed at 2026-09-09T17:47:35.783Z using CI run 34384462207, artifact
10117187871, source dc50f96ff469a93da8670e48e3f0613442f78667, checkout
aa1b9b715645317cd74e31d09b1feba2c916cbe0. Every manifest file hash was checked
before serving. Two synthetic Keepers with conflicting claims were visible; the
read failure, source metadata disclosure, keyboard focus and owner filter passed.
The 390x844 document had no horizontal overflow and its screenshot was visually
inspected. The page's build-identity notice is expected when using CI assets over
an existing server and is not deployment proof.

[Desktop](browser/desktop.png), [mobile](browser/mobile.png),
[receipt](browser/receipt.json). This proves the real Lab UI with synthetic context
responses, not deployed aggregation of live Keeper memories.
