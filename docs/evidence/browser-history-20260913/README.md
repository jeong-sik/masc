# Reading saved observations after the browser closed

Actual authenticated isolated-server/TUI capture used native source
`3e4c08c8856390c28fc0502f47142b5447131f7d` from run 34703965233.
Server SHA-256: `ff85fde118379a6b1a6dbf49b381514316570b71c48c2ffc89bcb0992a66553a`.
TUI SHA-256: `0b3599ee2bac61262023b8abdbab101ed2397953b74be3aad13ac55f0432c4b8`.
The report retains health provenance, an empty client inventory, successful
artifact-read checks and server/capture exit statuses.

The four observations were originally produced by a real Keeper at source
`fb8d2a312b550dd6e02d5857c3ddc989c950b05e`, not by this reader candidate.
The browser was already closed. The reader displayed Gamma, Beta, Alpha and
the initial scoped navigation observation from the actual persisted receipts.
Each `y` context matched keeper, execution ID, artifact reference, timestamp,
document ID, URL and truncation. `]` visited older observations; `[` returned.

This candidate required **a → h** (`via_automation=true`) because its disconnected
client picker blocked direct h. No browser session was opened by that workaround.
Later direct-h and Q repairs are not native-covered here. The separate connected
synthetic fixture log is not a disconnected/direct-h proof. No current-head or
later ownership/SSE proof follows from this earlier candidate execution.

`observation-N.png` is an xterm replay of actual native PTY bytes, not an actual
Firefox screenshot. The text beside it comes from that same terminal replay.
There is no contemporaneous alignment claim with a webpage screenshot.

Run `python3 audit.py` from any directory: it reads only local files and verifies
OSC52 contexts, receipt references, four blob hashes/byte counts and each replayed
URL/title/body combination, plus checksums. To independently rerender, install
Python Playwright with Chromium and ttyd, then run from this directory:

```
python3 replay.py observation-0.pty --columns 130 --rows 35 --output observation-0.png
```

Repeat for 1 and 2. For 3 use `observation-3-complete.pty`: the original
per-page capture stopped mid-redraw after OSC52. The complete fourth frame is
an exact prefix of history.pty through its next actual FRAME_END (`ESC[?7h`) terminator;
replay-boundary.json records byte offsets, and audit.py verifies the prefix.
`overview-complete.png/.txt` are the final fourth-frame replay. The audit rejects
old Alpha body text and requires blank rows below Text 1/4; merely finding a
new header and navigation labels is insufficient.
The original partial recording is retained. Copy completion alone is therefore
not evidence that a terminal redraw has completed. Replay starts a local terminal renderer, not MASC or Keeper.
`capture-original.py` is the exact historical capture script; its explicit owned
scratch paths and authenticated server prerequisites make it unsuitable as an
offline replay command. No token, login-private file, server configuration or
provider log is included. `tool-calls.json` is the actual bounded authenticated
API response from the isolated Keeper, rather than a generated fixture.

The final `overview-render-settled.png/.txt` replay waits for xterm's actual
full-row onRender event after refresh, then animation-frame completion and ttyd
resize-overlay disappearance. These APIs were exercised against the installed
ttyd/xterm. No fixed screenshot delay is used. Earlier images remain: the first
onRender-only image shows ttyd's resize badge. The clean final image and text
were inspected; no cache or rendering-race cause is asserted for earlier reports.
