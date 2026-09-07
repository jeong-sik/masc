# Firefox contexts measurement — 2026-09-07

Production OCaml WebDriver code was evaluated through the OCaml interpreter (no local MASC build) against isolated stock Firefox. The scenario observes nested cross-origin iframe controls, submits Unicode input inside that frame, returns to the top-level page, rejects a missing frame before mutation, accepts an alert, dismisses a confirm, supplies prompt text, and submits a local file as multipart form data. The fixture HTTP server checks the received file bytes.

`probe.log` contains the actual assertions; `sources.json` identifies the source files evaluated. `execution.json` records interpreter execution and image dimensions. `screenshot.png` captures the fixture viewport before the dialog/upload scenarios; it is not visual evidence of those later outcomes. The compiled counterpart runs in Browser Host Proof CI. These files do not claim a deployed MASC or live Keeper/model turn.

The updated measurement additionally opens a page with a load-time alert, recovers through its returned tabId, and creates a new tab after closing the previously current tab.
