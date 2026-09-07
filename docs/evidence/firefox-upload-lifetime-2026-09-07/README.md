# Firefox upload snapshot lifetime

Before: selecting a file and unlinking its backing path caused later Firefox
File.arrayBuffer to return AbortError (`before.json`). Selection completion is
not evidence that the browser copied the file bytes.

After: the production Browser_upload_lease staging code and Browser_webdriver
ran in the OCaml interpreter against an isolated stock Firefox session. The
shared scenario verifies private snapshot selection, callback return, later
File.text, multipart upload with server-side byte verification, retention after
tab closure, removal after confirmed session close, and preservation of the
caller source file. `probe.log`, `sources.json`, `execution.json` and the
viewport `screenshot.png` record this run. `failure-probe.log` records execution
of the production driver and lease code with injected transport failures plus
real Eio cancellation, covering unclaimed cleanup and claimed-file retention.

The CI executable uses the same scenario and production modules. This local run
interpreted source; it did not build MASC, run the Keeper sandbox backend, deploy
a binary, or measure a model-driven Keeper turn. The byte-authority mapping is
covered by the separate Keeper upload tests.

Reproduce the real Firefox scenario with:

```sh
python3 scripts/probe-firefox-controls.py --geckodriver /path/to/geckodriver --firefox /path/to/firefox --out /path/to/evidence
```
