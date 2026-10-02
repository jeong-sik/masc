# Historical Home viewport evidence

Source: `5924e6846516bb9bc97bbdf96b5a2abdd3a39294`.
[Targeted run 36664548724](https://github.com/jeong-sik/masc/actions/runs/36664548724)
failed overall. Its viewport suite passed: `Home viewport PTY: PASS (4 scenarios, 12 frames)`.
The twelve color/NO_COLOR frames cover unread and request states at 80×24,
120×32 and 160×48. Raw bytes and SHA256 provenance are in the manifest.

These are Chromium/xterm replays of CI fixture PTY bytes, not local or installed
TUI runs. This source predates full creation/draft integration and the request-ID
padding correction. It does not prove the current integrated head.

Visual inspection confirms individual requests and continuation in the same
80-column body, and no automatic Recent pane. The replay helper was corrected to include ttyd terminal padding and wait for font
initialization. The final composer row is fully visible in the corrected PNGs;
raw PTY bytes and decoded text remain identical. Capture geometry is recorded
per frame in the manifest. These historical frames still do not establish
current-head behavior or installed/runtime acceptance.
