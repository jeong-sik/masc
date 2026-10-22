# Installation model observations

Dashboard source `79e8a66286fd677c41e92b126d02060b51b3c6b9` preserves
the server's required `exact_outputs` rather than dropping them at decoding.
It displays model candidates, configuration failures and output declaration
provenance in the original installation's All Lanes detail. No model call,
installation selection or original history ID is synthesized from these fields.

The new API regression was first executed against unchanged production source
`a0d3f3197fb88005bd9f920ded9d915d2c8dccea` and failed because the decoded
declaration omitted `exact_outputs`. [The failure log](baseline-decoder-failure.txt)
is retained. After repair, [three selected suites](selected-dashboard-tests.txt)
pass 37 cases. Whole Dashboard TypeScript and six changed-file ESLint checks
also return zero. Commands, source blob hashes and artifact hashes are in
[the execution receipt](execution.json).
Published text logs omit only terminal blank lines; their artifact hashes and
the original raw command-output hashes are recorded separately.

## Browser scope

[The screenshot](model-routes-fixture.png) is an actual Chromium rendering of
the production `LaneInventoryPanel` and decoder with synthetic API responses.
The browser searched for and opened `Curator installation`; its configuration
is off with no workers. Classification candidates, a refused runtime, unavailable
briefing configuration and a retained table without a package output remain
visible independently of package activity. [Browser observation](browser-observation.json)
records the single fixture GET and the rendered model detail.

This is a component fixture, not the running full Dashboard or a real Curator
worker/provider session. Runtime configuration navigation is a generic link
to the existing editor; this probe did not save configuration or test that editor.

To reproduce from the recorded source, copy [browser-fixture.html](browser-fixture.html)
to `dashboard/.addon-model-probe-20261022.html`, use the existing Vite development
server and open `/dashboard/.addon-model-probe-20261022.html`. The fixture
intercepts all fetches: only `/api/v1/lanes` returns synthetic data, and other
fetches return 503. It does not connect to a live MASC server. Select the named
installation, then remove the copied temporary entry when finished.

## Separate TUI parent execution

The TUI history parent `a0d3f3197fb88005bd9f920ded9d915d2c8dccea` completed
[selected CI 39713823343](https://github.com/jeong-sik/masc/actions/runs/39713823343):
palette matching 19 cases and runtime state transitions 46 cases, 65 total.
This selected run does not compile the main TUI executable or execute the later
Dashboard changes. The separate [native run 39713826631](https://github.com/jeong-sik/masc/actions/runs/39713826631)
completed on workflow source `38b63de32b575ceb4eef6d26fdd9de4c7eccee81`, with
feature source `a0d3f3197fb88005bd9f920ded9d915d2c8dccea`. It built the matching
TUI, server and key-reference generator plus two suites, passing 24 + 5 = 29
cases. [Its receipt](native-tui-parent-receipt.json) was read from artifact
`12398028976`; the downloaded TUI, server and key-reference bytes match their
recorded SHA256 values. This proves compilation and the selected tests, not an
installed runtime or visible interactive TUI session.

Original A01–H06 criteria remain unchanged and incomplete. Curator builtin
retirement, real provider work, actual two-UI lifecycle, integration and installed
runtime verification are outside this receipt.
