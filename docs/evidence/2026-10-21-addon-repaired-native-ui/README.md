# Repaired native Add-on detail observation

Observed product: `15478fda04ffc7d6f4393fa3fffd45d7b70bc845` (PR #44838), native run [39603379628](https://github.com/jeong-sik/masc/actions/runs/39603379628), artifact 12347517820. Matching server and TUI binary hashes and embedded source identities were verified. The selected mixed TUI suite passed 22 tests and application suite 5; neither is full regression or visible-UI evidence by itself.

A real matching server/TUI and Docker/MCP observer ran in a separate temporary workspace on port 51623. Actual manual PTY input/output, interpreted cells and independently captured API/Docker observations are retained. Cell-derived PNGs, if present, are diagnostic renders, not physical desktop screenshots. No screen wording, layout, row-order or PTY assertions were added.

Observed manually:

- `01`/`02`: On, applied original worker `01a15e9c-7fad-7000-937e-b01fd76c5e1c`, `repaired-input-1` / `stop_requested`.
- `03`–`07`: actual TOML Off draft/save, cleanup, and original retained detail. Manual `r` preserves the original selected result and successful retained-slice coverage. This is the defect formerly reproduced in the historical 7b16 product.
- `08`: the same open detail remains populated later. This capture alone does not independently trace a cadence HTTP request; automatic cadence request proof is still separate.
- `09`: editing from the retained owner is refused; explicit navigation to the current declaration (`11`/`12`) is used. No implicit replacement owner is chosen.
- `13`–`16`: actual On draft/save yields a new worker `01a15ea2-34fe-7000-807a-f3b83ebd94a8`, new input `repaired-input-2` / `pause_requested`.
- `17`/`18`: original retained history still shows `stop_requested` after reconnect and manual refresh. A fresh API slice independently contains both original and new result IDs/evidence.
- `19`–`22`: actual final Off/save, API `inactive`, both lifecycle releases `released`. Exact container IDs are absent on the same Docker engine `ae0e98fe-d402-4dc7-88a8-685efbd65ae7`. The running/new container was independently inspected before final Off; the old one was already absent.
- Shutdown request and later observation distinguish requested termination from both PIDs absent and port connection refused. The driver's WNOHANG status is not used as a native child exit-code receipt.

These are separate reads, not an atomic snapshot. The TOML POST response body and initial source file were not separately retained; the actual TUI save receipt and independently returned API state are the recorded observations. Source event timestamps belong to synthetic payloads and do not measure input/paint latency. `source-2.json` is the later synthetic input. Manifest/image are existing VST Phrase observation fixtures; no VST/audio/player/device, model, browser or agent action was executed. The image's process metadata does not prove audibility. No Remove TOML/reinstall, Dashboard combination, operator install or Release/Tag claim is made.

The G06 partial-history-failure fix in #44843, source `2c0e4abaf3322f2d9a4ed9e336b4cd230b4da1fd`, is a later, separate candidate. It was independently source-reviewed; its selected native run 39607780651 completed with 23+5 passing checks. The separate actual failure/recovery observation is published in [#44850](https://github.com/jeong-sik/masc/pull/44850); it is not part of this 15478 execution. This 15478 execution does not certify that newer delta. The original 54 worklist criteria remain unchanged.

Private login/token/config files and server logs are excluded. The publication allowlist is checked against the exact private bearer bytes without printing them. `files.sha256.json` excludes itself. This 53-file selection is published in [#44849](https://github.com/jeong-sik/masc/pull/44849). Independent evidence review, formal approval and integration remain separate. Publication changes no frozen runtime result or 54-item completion criterion.
