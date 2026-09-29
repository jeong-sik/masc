# Browser / Lanes truth audit — 2026-09-29

## Finding

The running MASC instance cannot serve Stagehand. At 2026-09-28 23:41 UTC
(2026-09-29 08:41 KST), its active configuration contained neither
`[browser.stagehand]` nor the `browser_stagehand_exact` exact-output binding.
The authenticated lane response reports `configured=false`,
`configuration_state=unconfigured`, `status=unavailable`. The MCP
`masc_browser_session(action=status,lane=stagehand)` call independently returns
an error asking for `[browser.stagehand]`; see `stagehand-status.txt`.
No production configuration, browser session, or deployment was changed.

The current source has Stagehand session, read, pointer, and model paths. That
is not proof of an operational end-to-end model/browser integration. The
[existing real-model probe](https://github.com/jeong-sik/masc/pull/39390) remains
open. Its [raw diagnostic results](https://github.com/jeong-sik/masc/blob/1240f8cbeab343d99c481f62d6758a5d8d356887/docs/evidence/stagehand-real-model-20260927/typed-diagnostic/results.jsonl)
record nine three-trial summaries, each with `valid=0` and `shape_valid=0`,
on source `fedd7dbabfcbdd14eab3480531abe7323f0148d9`. That is 0/27 on that
recorded setup, not a fresh result for this branch or every model/provider.
The [Stagehand upstream](https://www.stagehand.dev/) describes the extension,
browser and model operations separately; opening a browser alone is not
model-driven act/extract proof.

## Display defects repaired

- TUI and dashboard headings now say **Lanes**. TUI navigation distinguishes
  **Runtime lanes**, **All runtimes**, and **Lanes**.
- Dashboard now shows the server's purpose and configuration state, including
  Stagehand's explicit limitation that run records are not retained yet.
- Failed lane refresh preserves the previous rows with **STALE**, the failure,
  and the original observation time. Successful refresh clears the warning.
- TUI absence of retained terminal evidence no longer claims no run finished.
- Stagehand viewport help no longer falsely claims click/drag are unsupported.
- Browser open/close/goto progress names the selected source.
- Successful server-owned browser close no longer reads the closed session and
  transforms success into a `no_session` error; it clears stale content and
  displays the closed state with an open action.

## Evidence boundaries

`runtime-observed.json` records the running binary commit and hash separately
from the edited source. The live dashboard reports unknown source provenance;
there is no claim that it runs this branch. `lanes-observed.json` is an actual,
authenticated server observation, not a generated fixture.

`lanes-observed.png` and `lanes-stale.png` render that saved response through
the changed dashboard component and HTTP decoder in a real headless Chromium.
The stale response is deliberately injected HTTP 503. Other execution-history
sources are empty fixtures. These images prove this component's display and
refresh behavior, not Stagehand execution or live dashboard deployment.

Validation performed:

- Dashboard focused tests: 3 files / 26 tests passed.
- Dashboard `tsc --noEmit`: passed.
- `dashboard/e2e/lanes-truth.mjs`: six observed lanes, Stagehand limitation,
  failed-refresh retention and recovery passed; screenshots inspected.
- OCaml parsing of the two edited TUI implementation files: passed. This is
  syntax-only; no local build was run.
- Browser lifecycle PTY scenarios added for automation and Stagehand. Current
  branch binary execution and compilation are delegated to CI, not claimed
  by local syntax checks or the installed older binary.
- Independent source review found the close/read bug and inaccurate hints;
  fixes reviewed, including correction of a cadence race in the PTY scenario.

From `dashboard/`, reproduce the browser check with the dev fixture server running:

```sh
INTERNAL_AGENTS_FIXTURE_URL=http://127.0.0.1:5197/dashboard/dev-fixtures/internal-agents-monitor-fixture.html \
INTERNAL_AGENTS_ARTIFACT_DIR=../docs/evidence/browser-lanes-audit-20260929 \
pnpm exec node e2e/lanes-truth.mjs
```

Remaining operational work: establish a working model binding and Chromium
extension configuration, run real model plus browser act/extract checks, and
install source-matched server/TUI/dashboard artifacts. The shared Stagehand
session must not be repurposed or closed without its ownership being clear.

## Deployed dashboard mismatch and follow-up

The actual deployed dashboard was opened in a separate headless browser using
an existing admin credential (the credential was not logged or included in the
URL). `deployed-monitor-before.png` is its real rendered monitor, not a replay.
It displayed zero exact/verification counts while reporting these errors:

- `Invalid exact lane runs response: runs[0] fields mismatch (missing=[], unknown=[run_kind])`
- `Invalid verification runs response: runs[2] fields mismatch (missing=[retryable], unknown=[])`
- `Invalid standalone lanes response: root.schema is unknown`

This establishes deployed frontend/backend drift, independently of the unknown
asset provenance in `/health`. The current source already decodes the current
lane schema and exact run kind. Source edits do not replace the installed assets.

The follow-up keeps successful rows independently for exact, verification and
Fusion sources. A failed first read shows **— / 관측 불가**, not a measured zero;
a failed later read retains the last successful rows with **STALE**. Successful
empty recovery legitimately replaces retained rows with zero. The owner matrix,
filters and empty timeline use the same reading state. `runs-unavailable.png`
replays a deliberate exact-source HTTP failure through the changed component.
The focused regression exercises first failure, one successful run, later
failure, and successful empty recovery.

PR #39783 was merged outside this session at 2026-09-29 00:21:00 UTC by account
`jeong-sik`, merge `8d2b8148d969eaddd3dbb74a710ad9f8fed43475`. At the post-merge
inspection all five required checks were still in progress and the separate
`PR required success` check had failed. This is not a CI pass or an action by
this coding session. A [focused TUI run](https://github.com/jeong-sik/masc/actions/runs/36505146452)
was dispatched on that exact merged SHA for browser lifecycle, lane heading,
stale failure, async reads, decoding, and keyboard scenarios. Its result must
be read separately; dispatch is not completion evidence.
