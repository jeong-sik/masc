# Browser per-backend activity — configuration, admission and readout

Browser live, automation and stagehand have independent activity settings. Off
preserves paths, connected clients and existing sessions. New work is rejected
before effects; server status/close and already accepted work remain available.
Activity follows Runtime's immutable published configuration. Executable and
profile paths are installed at server startup. No activity editor is added here.

The accepted one-deployment transition reads automation paths from either
`[browser]` or `[browser.automation]`, rejects both together, and treats omitted
activity as enabled. Operator file migration and later strict removal are not
performed by this change. No live runtime configuration was edited.

## Executed

Captured text logs have trailing whitespace and trailing blank lines normalized;
command output content and result values are unchanged.

- `check-browser.py .`: copies complete actual Browser configuration/admission
  and leaf dependencies, compiles/links with OCaml 5.5.1, and executes the actual
  authored test: **13 pass**. Sources and commands are in `leaf-provenance.json`;
  log is `leaf.txt`. No replacement product module is used. Activity observers,
  executors and live poll/result are controlled test fixtures. This covers off,
  unobserved, optional-document admission, status/close and accepted work.
- `check-inventory.py`: **15 pass**, actual TUI inventory decoder/renderer and
  exact production decoder blocks extracted by markers. Namespace aliases are
  recorded by the script. `inventory-provenance.json` and `inventory.txt` describe
  the source closure. This is not the complete TUI executable or PTY.
- Web **11 tests / 2 files**, TypeScript and scoped lint pass. Commands/source
  hashes: `web-provenance.json`. The initial new UI test selected two identically
  labelled Stagehand families; `web-tests-initial.txt` retains that harness
  failure. Selecting by the visible identity search fixes the test; no product
  behavior was changed to hide the duplicate label.
- Chromium with actual Status, inventory, API decoders and current Vite/CSS:
  **6 checks**, 3 inventory GETs, no mutation, page error or unexpected route.
  Synthetic observations show off+registered, off+connected, unobserved+registered
  and refreshed on. Mobile has no horizontal overflow. The first fixture lacked
  current Vite/CSS configuration; final captures use the actual dashboard config.
  Retained screenshots/results are in
  [the capture bundle](../dashboard/2026-10-04-browser-lane-activity/README.md);
  [the executable fixture](../../../dashboard/fixtures/2026-10-04-browser-lane-activity/browser-fixture.mjs)
  is separate from captured output.
- OCaml syntax parsing: **34 changed/new ML/MLI files pass** (`syntax.json`).
  Python scripts/fixture AST, tool TOML decoding and `git diff --check` pass.

## Authored, not executed

`test_runtime_config_validity.ml` adds a production Runtime test for boot load,
CAS save and conflict, malformed Browser settings, pre-rename write failure,
visible replacement with parent-fsync failure, snapshot restore and reload.
Its full dependency closure has not been compiled/linked/executed here. Calling
`Runtime.init_default` in that scenario is not process restart evidence.

No full Runtime/server/native TUI type/link, real Browser sessions, model call,
PTY, local Dune, CI, main integration or deployment was performed. The server
observer bridge and common save publication are source-reviewed, not exercised
by the injected leaf test. These scopes must remain distinct.

## Remaining work

Dedicated Browser TUI/Web draft/preview/CAS controls, Runtime/server integration
execution, review of refreshed lower-stack identities, main integration and
operator deployment remain. The operator's complete Lane UX improvement goal is
not complete. Setup-required/unconfigured startup does not install an executor
later through config resume; paths and that installation require a restart.

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

The [reproduction source](../../../dashboard/fixtures/2026-10-04-browser-lane-activity/browser-fixture.mjs) is separate from the retained captures.

From the repository root, manually verify this index, the original manifest's
bytes, every current location and retained capture digest:

```sh
python3 scripts/check-evidence-locations.py docs/evidence/2026-10-04-browser-lane-activity/current-locations.json
```

Editable entries are location checks, not current-byte approval. Historical Git
objects must be available locally; the checker reports an unavailable object as
a failure instead of treating missing evidence as a pass.
