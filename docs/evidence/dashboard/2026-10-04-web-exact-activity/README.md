# Web Exact activity controls

Source scope: All Lanes details and Runtime Lane candidate cards now open the
same workspace/lane-owned activity draft. Toggle is local; explicit save runs
preview and source CAS. Existing raw TOML drafts remain independent. Their
projections refresh when another writer commits; a known newer write also
invalidates an older in-flight comparison read.

Executed from the repository root:

```sh
pnpm --dir dashboard test src/components/exact-lane-activity-panel.test.ts src/components/lane-inventory-panel.test.ts src/components/runtime-toml-editor.test.ts src/lib/runtime-toml-config.test.ts src/api/dashboard.test.ts
pnpm --dir dashboard typecheck
pnpm --dir dashboard exec eslint src/lib/exact-lane-activity.ts src/lib/exact-lane-activity-session.ts src/lib/exact-lane-observation.ts src/lib/runtime-toml-session.ts src/components/exact-lane-activity-panel.ts src/components/exact-lane-activity-panel.test.ts src/components/lane-inventory-panel.ts src/components/runtime-exact-lane-editor.ts src/components/runtime-toml-editor.ts
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:9 node dashboard/fixtures/2026-10-04-web-exact-activity/browser-fixture.mjs
```

Results: 455 tests in 5 files, full TypeScript check and the named source-file
lint pass. Chromium exercises actual Status, router, Runtime raw editor, Lane
inventory/activity components and API decoders against synthetic HTTP. Twelve
checks pass, including draft-only navigation, explicit conflict/reapply,
retaining the independent raw draft, both control entrypoints, and file On
versus observed Off with a kept-registry receipt. A direct Runtime save holds
setup resume while both observation screens unmount and remount; after release
they read the published state and keep the activity/receipt open. It makes four
explicit raw save attempts (one conflict, three commits), four previews and
three setup resumes.
There are no page errors, unexpected API routes or mobile horizontal overflow.
The screenshots include desktop, mobile and the resumed Runtime activity.

Independent source review found missing post-resume observation refreshes in
Runtime and in remounted All Lanes, plus the activity panel closing during
projection refresh. `resume-race-before.txt` reproduces both stale observations
as failing actual-component tests on the initial implementation. The first two
test-harness attempts lacked the resume-state export and provider descriptor;
those fixture errors are kept separately as `resume-race-initial-*.txt` and are
not the defect reproduction. After the fix, `resume-race-after.txt` passes 31
activity tests, including both screens with and without remount. The final
full focused test run and browser evidence include these fixes.

Harness corrections before the final run: the fixture initially lacked a
required provider-protocol descriptor, the reopen step raced its GET before
injecting a concurrent write, and keeper-deletion refresh lacked a synthetic
response. These observations are kept in the initial/read-race/missing-fixture
logs. An early root-directory Vite run omitted dashboard CSS processing; the
final harness pins the dashboard root/config and loads the entrypoint's actual
stylesheet imports. The required proxy variable points at discard port 9;
Playwright intercepts all API requests, including unexpected ones. Final
screenshots and results come from this correctly styled harness.

The TypeScript check also caught a missing `next_boot_publishes` field in a
kept-registry test fixture; the fixture was corrected before the final checks.
No Dune/native backend/TUI/model/CI/deployment run occurred. Synthetic browser
writes do not establish that a deployed registry or Curator actually resumed.
F1 still needs Curator wake and native/integration proof. Other Lane-family
controls, package discovery/forms and Goal gaps remain in the overall goal.

## Current locations and recorded capture identity

[source-hashes.json](source-hashes.json) is the immutable capture-time path/digest record. Its
recorded paths describe the original run, rather than this checkout's current
layout. Use [current-locations.json](current-locations.json) to locate every
recorded entry after the repository reorganization. The sidecar's `files` keys
are current repository-relative paths; each entry retains its original
`recorded_path` and `recorded_sha256`.

`editable_reproduction_source`, `editable_source` and `editable_document` entries
may have changed since capture. The recorded digest is not a claim about those
current bytes or evidence of a new run. `retained_capture` entries preserve the
recorded bytes. No current-file digests are cached in this location index.

The [reproduction source](../../../../dashboard/fixtures/2026-10-04-web-exact-activity/fixture.ts) is separate from the retained captures.

From the repository root, manually verify this index, the original manifest's
bytes, every current location and retained capture digest:

```sh
python3 scripts/check-evidence-locations.py docs/evidence/dashboard/2026-10-04-web-exact-activity/current-locations.json
```

Editable entries are location checks, not current-byte approval. Historical Git
objects must be available locally; the checker reports an unavailable object as
a failure instead of treating missing evidence as a pass.
