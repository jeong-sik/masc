# Browser / Lanes truth audit — 2026-09-29

## Final live activation — 2026-09-29

Stagehand now completes model-driven browser operations on the live MASC
server at port 8935. By **02:13:48 UTC**, a fresh session (`reused=false`)
navigated to the controlled local fixture at port 8998, extracted **42 USD**,
clicked through `act`, and returned **Confirmed by Stagehand** on the
subsequent read. This verifies the configured model/browser path against that
fixture; it does not rerun or overturn every case in the earlier 27-trial probe.

The active setup uses Stagehand extension **4.1.0**, Chromium artifact **1228**, and
the model slots `glm-coding.glm-5.3-flash` and
`ollama_cloud.ollama-cloud-deepseek-v4-1-flash`. Configuration, installation and
deployment were changed after the initial observation recorded below.

Runtime and frontend provenance are separate:

- The live server binary and installed TUI identify source
  `1beabf795c64d5211714e4eed4850740fb9b6cce`.
- The installed dashboard was produced by successful
  [CI run 36509632826](https://github.com/jeong-sik/masc/actions/runs/36509632826)
  from source `2f1ddd7733dc5c23a80f227554779efd95485d44`. Its assets were installed under
  `/Users/dancer/me/assets/dashboard`, with a backup of the previous assets.
  After deployment, the served index SHA256 was verified as
  `47715f46676a4d8f930f793d04ce092fef8b11e554269d067200ad167f280163`.
- These are separately identified artifacts, not a claim that the server,
  TUI and dashboard belong to one source-matched release.

Final evidence:

- [Live runtime identity](live-activation/live-runtime.json) and
  [actual lane configuration observation](live-activation/live-lanes.json).
- [Model extraction](live-activation/live-extract.json),
  [model action](live-activation/live-act.json),
  [read after the action](live-activation/live-read-after.json), and
  [confirmed browser screenshot](live-activation/live-stagehand-confirmed.png).
- [Dashboard build receipt](live-activation/dashboard-build-receipt.json),
  [deployment verification](live-activation/deployment-verification.json), and
  [actual installed dashboard screenshot](live-activation/deployed-lanes.png).
  The installed screenshot was captured after deployment; the earlier fixture
  and preview images below are different observations.
- [Installed TUI test results](live-activation/installed-tui-tests.json): isolated
  PTY browser navigation and lifecycle scenarios for both automation and
  Stagehand, plus lane stale-state and heading scenarios, passed. These PTYs
  use HTTP fixtures; live model execution is established by the separate
  Stagehand receipts above.

**Remaining limitation:** Stagehand run records are still not retained. The
dashboard exposes that limitation; successful live act/extract receipts do not
establish a retained Stagehand run history.

## Initial finding — 2026-09-28 23:41 UTC

The running MASC instance could not serve Stagehand. At 2026-09-28 23:41 UTC
(2026-09-29 08:41 KST), its active configuration contained neither
`[browser.stagehand]` nor the `browser_stagehand_exact` exact-output binding.
The authenticated lane response reported `configured=false`,
`configuration_state=unconfigured`, `status=unavailable`. The MCP
`masc_browser_session(action=status,lane=stagehand)` call independently returned
an error asking for `[browser.stagehand]`; see `stagehand-status.txt`.
No production configuration, browser session, or deployment had been changed
at this initial audit stage. The final activation above supersedes this
operational finding; these original observations remain historical evidence.

Initial source inspection found Stagehand session, read, pointer, and model
paths. That inspection alone did not prove an operational end-to-end
model/browser integration. The
[earlier real-model probe](https://github.com/jeong-sik/masc/pull/39390)'s
[raw diagnostic results](https://github.com/jeong-sik/masc/blob/1240f8cbeab343d99c481f62d6758a5d8d356887/docs/evidence/stagehand-real-model-20260927/typed-diagnostic/results.jsonl)
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

## Initial evidence boundaries

`runtime-observed.json` records the running binary commit and hash separately
from the edited source. That initial live dashboard observation reported unknown
source provenance; it did not establish that the dashboard ran this branch.
The final deployment receipt above records the later installed assets.
`lanes-observed.json` is an actual,
authenticated server observation, not a generated fixture.

`lanes-observed.png` and `lanes-stale.png` render that saved response through
the changed dashboard component and HTTP decoder in a real headless Chromium.
The stale response is deliberately injected HTTP 503. Other execution-history
sources are empty fixtures. These images prove this component's display and
refresh behavior, not Stagehand execution or live dashboard deployment.

Validation at the initial audit stage:

- Dashboard focused tests: 3 files / 26 tests passed.
- Dashboard `tsc --noEmit`: passed.
- `dashboard/e2e/lanes-truth.mjs`: six observed lanes, Stagehand limitation,
  failed-refresh retention and recovery passed; screenshots inspected.
- OCaml parsing of the two edited TUI implementation files: passed. This is
  syntax-only; no local build was run.
- Browser lifecycle PTY scenarios were added for automation and Stagehand.
  Compilation and execution were then pending CI; the initial local syntax
  checks were not execution evidence. Subsequent installed-TUI PTY results
  are recorded in `live-activation/installed-tui-tests.json` above.
- Independent source review found the close/read bug and inaccurate hints;
  fixes reviewed, including correction of a cadence race in the PTY scenario.

From `dashboard/`, reproduce the browser check with the dev fixture server running:

```sh
INTERNAL_AGENTS_FIXTURE_URL=http://127.0.0.1:5197/dashboard/dev-fixtures/internal-agents-monitor-fixture.html \
INTERNAL_AGENTS_ARTIFACT_DIR=../docs/evidence/browser-lanes-audit-20260929 \
pnpm exec node e2e/lanes-truth.mjs
```

The model binding, extension configuration, live act/extract verification and
artifact installation that were pending at this stage are covered by the
final activation above. Stagehand run retention remains absent. The shared
Stagehand session must not be repurposed or closed without its ownership
being clear.

## Earlier deployed dashboard mismatch and follow-up

Before the final asset deployment, the actual dashboard was opened in a
separate headless browser using
an existing admin credential (the credential was not logged or included in the
URL). `deployed-monitor-before.png` is its real rendered monitor, not a replay.
It displayed zero exact/verification counts while reporting these errors:

- `Invalid exact lane runs response: runs[0] fields mismatch (missing=[], unknown=[run_kind])`
- `Invalid verification runs response: runs[2] fields mismatch (missing=[retryable], unknown=[])`
- `Invalid standalone lanes response: root.schema is unknown`

This established deployed frontend/backend drift, independently of the unknown
asset provenance in that `/health` observation. The source at that point
already decoded the current lane schema and exact run kind. Source edits alone
did not replace the installed assets; final installation and the subsequent
served-asset verification are recorded above.

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

The completed PR check run 36502643643 on source
`5e6519eaa08b85722c196b89fdd656ef0948ff09` passed dashboard typecheck, release
build, lint and TLA. Its development check passed the Browser lifecycle PTY,
lane heading and stale-failure PTYs, and all 344 decoder tests, then failed
`test_tui_selection_visibility.py:77` waiting for the entire renamed Runtime
tab label. The follow-up waits for the actual restored runtime row, followed
by the existing Runtime ID assertion; a narrow tab strip does not guarantee
that its entire count label fits. The failed aggregate is not called green.


## Final follow-up validation

The deployed decoder also needed three corrections against the current OCaml
producer: `not_reviewed` no longer emits `retryable`, `review_cancelled` carries
a detail, and approved reasons may be empty strings. The focused API, panel and
monitor tests passed (43 tests), along with TypeScript checking. The successful
dashboard artifact run above also ran the requested feature tests before bundling.

The earlier focused Linux TUI run 36505146452 on `8d2b8148d969eaddd3dbb74a710ad9f8fed43475`
completed with failure in `test_tui_keyboard_rosters_pty.py` via
`keeper_selection_identity_interaction` waiting after refresh. It is not reported
as a successful aggregate. The installed macOS binary checks recorded above are
a separate, focused result; the unused release-candidate build is not deployment
evidence.
