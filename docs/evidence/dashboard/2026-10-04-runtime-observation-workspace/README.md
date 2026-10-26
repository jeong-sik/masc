# Runtime observation workspace isolation

Parent: `70a3abb094378f7cf7f28468be3ba5c966ad703d` (#41180).
This change repairs B9. Browser/machine activity, package controls and Goal
work remain separate.

## Behavior and causal boundary

Overview metrics and provider usage carry the accepted workspace authority
object. Changing or withdrawing that authority hides old values immediately;
effects abort previous reads and fetch the new workspace. Success and failure
paths also compare authority, including A → B → A. Metrics retain the existing
30-second/focus/visibility refresh. Probe reads have an owned controller;
refresh, workspace changes and unmount retire the previous request.

Manual account login results carry account/workspace identity. Invalidation
uses a layout effect so the first DOM click cannot later be invalidated by a
pending passive effect. CLI probes remain manual. This UI does not terminate
already-started backend CLI work.

## Executed evidence

- `before.txt`: parent product with nine new regression tests: seven failed,
  two passed. One failure is the absent probe AbortSignal option; others concern
  new-workspace observations. `before-test-source.txt` preserves the exact
  nine-test source; its hash matches `before-provenance.json`.
- Independent source review found a first-click pending-state regression in
  the initial patch. `login-first-click-before.txt` records its one-test failure;
  the matching WIP source and source/test hashes are retained alongside it.
- `tests.txt`: final four focused files, 62 tests passed, including the added
  direct-render first-click scenario. The initial test import failure came from
  a whole-module core mock missing store exports; `tests-initial.txt` retains
  it. The fixture now preserves actual core exports and mocks only GET/POST.
- `typecheck.txt` and `lint.txt`: whole dashboard TypeScript and scoped ESLint
  passed. Empty logs mean the commands produced no diagnostics.
- `browser-result.json`: Chromium, actual styled components/API decoders and
  synthetic HTTP, eight checks passed. Three screenshots record B failure,
  B recovery and new A readings at mobile width. One explicit login probe POST,
  no configuration writes, no unexpected API routes, no page errors.
  The first launch lacked the required dev proxy env; the second intercepted
  source-module URLs containing `/api/`. Those logs are retained. The final
  harness restricts interception to API endpoint paths.

No real backend, provider CLI, model, native TUI/PTY, full SPA routing, CI,
main integration or deployment was executed. Source differs from main in the
lower stack; these results belong to the candidate. Text logs retain their
content with trailing blank lines removed for repository whitespace checks.

## Reproduce

From `dashboard/`, use dependencies matching `package.json` and the lockfile:

```sh
pnpm test src/components/runtime-observation-workspace.test.ts src/components/overview/runtime-stats.test.ts src/components/tools/config-resolution-panel.test.ts src/lib/runtime-workspace-resource.test.ts
pnpm typecheck
pnpm exec eslint src/components/runtime-observation-workspace.test.ts src/components/overview/runtime-stats.ts src/components/overview/runtime-stats.test.ts src/components/tools/config-resolution-panel.ts
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:9 node fixtures/2026-10-04-runtime-observation-workspace/browser-fixture.mjs
```

The loopback proxy is unused: API endpoints are intercepted. The browser
harness opens its own ephemeral Vite port and closes it on completion.
Before evidence temporarily used the two changed product files' parent bytes,
restored in `finally`. Parent hashes and command are recorded; other product
sources match the base. The original nine-test source was reconstructed by
removing the later first-click case/imports and verified against its recorded
SHA256 before being retained here.

## Current locations and recorded capture identity

[manifest.json](manifest.json) is the immutable capture-time path/digest record. Its
recorded paths describe the original run, rather than this checkout's current
layout. Use [current-locations.json](current-locations.json) to locate every
recorded entry after the repository reorganization. The sidecar's `files` keys
are current repository-relative paths; each entry retains its original
`recorded_path` and `recorded_sha256`.

`editable_reproduction_source`, `editable_source` and `editable_document` entries
may have changed since capture. The recorded digest is not a claim about those
current bytes or evidence of a new run. `retained_capture` entries preserve the
recorded bytes. No current-file digests are cached in this location index.

The [reproduction source](../../../../dashboard/fixtures/2026-10-04-runtime-observation-workspace/browser-fixture.mjs) is separate from the retained captures.

From the repository root, manually verify this index, the original manifest's
bytes, every current location and retained capture digest:

```sh
python3 scripts/check-evidence-locations.py docs/evidence/dashboard/2026-10-04-runtime-observation-workspace/current-locations.json
```

Editable entries are location checks, not current-byte approval. Historical Git
objects must be available locally; the checker reports an unavailable object as
a failure instead of treating missing evidence as a pass.
