# Home viewport CI evidence

The [targeted Test run 36654334047](https://github.com/jeong-sik/masc/actions/runs/36654334047)
completed successfully at source/test head
`45c065b875c550e7109e59d86d3d2c31de9422da`. Its raw log includes
`Home viewport PTY: PASS (4 scenarios, 12 frames)` and twelve
`HOME_JOURNEY_FRAME` payloads. That head includes the Home implementation
`6ac4da4e23d3a1a66422c76e89ebad102dbcf5f3` plus the focused acceptance suite.

These PNGs are **Chromium/xterm replays of the actual CI fixture PTY frames**.
They are not HTML design mockups, a local TUI binary run, an installed binary,
or production observations. No names or screen text were replaced. The long
escaped workspace name is the harness's terminal-injection fixture; it is not
an operator workspace name. No provider was invoked by these fixtures.

[manifest.json](manifest.json) records the run, source/test head, full downloaded
log digest, each raw frame digest and the xterm geometry observed after replay.
Every PNG has an accompanying `.pty` raw frame and `.txt` read directly from
xterm's visible buffer. A separate binary digest or embedded build commit was
not collected by this Test run; no installed-binary provenance is inferred.

| Frames | Fixture state | Color |
|---|---|---|
| 01–03 | Approval sources not fully read | Normal |
| 04–06 | Approval sources not fully read | NO_COLOR |
| 07–09 | Three human approval requests | Normal |
| 10–12 | Three human approval requests | NO_COLOR |

Each group covers 80×24, 120×32 and 160×48, in that order. The suite verifies
decision reading, continuation, recipient selection and Enter→Approvals at
each size, rejects product POSTs, checks final row addresses and fixture cell
widths, and verifies absence of renderer color sequences under NO_COLOR.

Visual inspection is separate from those assertions. This evidence does not
cover creation, resumed drafts, request-specific detail identity, production
Keeper turns, shorter terminal heights, or time to first action. Color and
font acceptance on the operator's Ghostty remain unmeasured.

Visual finding: the 160-column frames (03, 06, 09, 12) automatically add the
global Recent pane on the right. The focused assertions pass because the
principal actions remain visible, but this contradicts the Home design's
requirement that wider terminals do not add default panels. That remains an
implementation gap; these screenshots must not be presented as full design
acceptance.

To reproduce the replay, first verify the downloaded run's head and success,
then use an isolated local ttyd listener and Playwright Chromium:

```sh
gh run view 36654334047 --log > /tmp/home-viewport.log
python3 -P docs/evidence/tui-home-journey-20260930/replay-ci-frames.py \
  --log /tmp/home-viewport.log --out /tmp/home-viewport-replay \
  --source-sha 45c065b875c550e7109e59d86d3d2c31de9422da \
  --run-id 36654334047
```

The replay uses `/bin/cat` as ttyd's idle child and feeds the saved ANSI bytes
to xterm directly. It checks geometry and required text and waits for ttyd's
own resize overlay to disappear before capture. It does not build or launch
MASC, contact its runtime, or alter the frame payloads.
