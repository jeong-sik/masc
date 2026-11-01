# Exact native Ego loading-recovery helper

This selected record demonstrates the JavaScript recovery component on installed
Ego Lite0.6.2.5 / Chromium156.0.8078.74 / Node24.22.1. It does **not** demonstrate
OCaml typing, browser Add-on/host dispatch, candidate installation, rendered UI,
input release, full SDK parity or an autonomous Keeper task.

The implementation was captured at committed recovery HEAD
`a906aff2bfec5587ff62496863f913532832a63b`. The captured implementation bytes
exactly match that HEAD
(SHA256 `aef4b6387d27b072b2f47ce1c9b3753174ef07994724cec228d6c28756d2cf4e`).
The actual captured `git status --short` output was empty.
`capture-provenance.json` binds those source bytes and the extracted script;
the helper script SHA256 is
`3bb0ac7340b735b11d0cc6865677226bff47f57148a32eeba3fb480b6f48ec84`.
The later WebDriver closed-pattern repair in another file is outside this run.

Only a newly created owned Pagep11 in existing agent-owned Space6 was operated.
The original Page was never operated. A normal owned-Page helper smoke returned.
Then a controlled `/stall` endpoint accepted the navigation but sent no headers.
The SDK's own default produced `EGO_NAVIGATION_TIMEOUT` with `timeoutMs=15000`,
`committed=false` and `waitUntil=load`. An ordinary Page.info call then failed with
`EGO_CDP_REQUEST_TIMEOUT` for Runtime.evaluate, also at its native15000ms default.
No explicit SDK timeout, host deadline or input was supplied.

The exact helper resolved the unique native inventory row and used its canonical
Page handle. `Page.stopLoading` returned on the same target without requiring a
Page URL/info/snapshot first. A separate fresh URL/title/snapshot read succeeded
on the prior ready document. Its target ID stayed unchanged. Pagep11 was closed
once, and final inventory confirmed it absent while the original Page remained.
No Space creation, finish, claim/takeover, server restart, configuration change,
manual helper installation or synthetic input cleanup occurred. A command-return
acknowledgement alone was not treated as document readiness or key release.

`selected-result.sanitized.json` is a derivative. It omits an unrelated original
Page title that the SDK added to its global snapshot prefix, and omits that
Page's target/final inventory identity. The controlled fixture snapshot body and
selected native failures/recovery/cleanup receipts are retained. Raw captures
were not rewritten; their original digests and local location remain in
`capture-provenance.json`. Those raw digests certify the raw bytes, not this
sanitized derivative. No Page screenshot was captured in this run.

Files:

- `captured-helper.ml` and `captured-helper.js`: exact captured source and script.
- `captured-probe.js`: exact native probe script, including its historical local
  origin and observed Space6. It creates/closes only its new fixture Page.
- `fixture.py`: readable reconstruction of the executed controlled HTTP fixture,
  with the exact HTML and stalled-response behavior; it is not claimed as a
  byte-identical capture of the original inline host driver.
- `installed-version.txt`: captured CLI version output.
- `capture-provenance.json`: source/runtime identity and original raw byte hashes.
- `manifest.json`: hashes for the intentionally retained selected bundle.

For a new authorized reproduction, start `python3 fixture.py <new-artifact-dir>`.
Use its printed localhost origin in a **copy** of `captured-probe.js`, and supply
only the explicitly authorized continuing agent-owned Space ID/name. The SDK
Node process does not inherit shell environment variables. Execute the copied
script with `ego-browser nodejs`, retaining both stdout and stderr. Shut down the
HTTP fixture after the probe. Preserve the original captures; write new results
under `artifacts/`, never into this bundle. A changed script is a new run, not the
captured script hash. Snapshot output may again contain unrelated Space titles;
review privacy before retaining or publishing it.
