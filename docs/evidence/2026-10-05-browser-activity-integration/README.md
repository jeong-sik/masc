# Browser activity parent integration and preselection repair

Original PR head: `d5a6340dd64f6b0a0dfacf27e8902731a6c13682`.
Response checkpoint: `dc57c06bf368362c3904f7bc9c3734c913bc1dd2`.
Actual integrated parent #41182: `8d13bef961ec26f9b49a491c3fccda40ec6dc36d`.
Compiled/tested source tree: `43c43b763e3680831a3d69abe0b1492fe6a9eac6`.
This evidence is added afterward; product and test bytes are unchanged.
The real parent merge was clean. No response logic was changed during integration.

The response checks activity before selecting a live client, with a mandatory
verb at all callers. It preserves status/close exemptions, the admission mutex
recheck, accepted work, and disabled-activity precedence over a stale target.
The actual tool regression checks disabled live activity with no clients,
multiple clients, and a stale selected client. It retains enabled-lane selection
errors and verifies no Browser command is queued.

## Executed locally after integration

- Focused repository wrapper build, OCaml 5.5.1, `DUNE_JOBS=2`, cache disabled:
  `test/test_browser_activity.exe`, `test/test_browser_lane.exe`,
  `test/test_browser_lane_watched_work.exe`, `test/test_browser_surface.exe`.
- Actual native executables: activity **15**, lane **8**, watched work **3**,
  actual tool surface **14** tests PASS (**40 total**).
- Additional focused build: `test/test_runtime_config_validity.exe`.
  The executable's list identifies `runtime TOML gate`, case `0`, as
  `Browser activity follows the visible config across save failure and reload`.
  `test 'runtime TOML gate' 0` reports exactly **1 test run**, PASS. This exercises
  boot load, CAS/conflict, malformed input, pre-rename failure, visible rename
  with uncertain durability, snapshot restoration, and configuration reload.
  Calling Runtime initialization in this test is not process restart evidence.
- All native executions use the repository test stanza environment: empty
  `MASC_BASE_PATH`, `ZAI_API_KEY`, and `TYPESAFEAI_API_KEY`; sandbox preflight and
  Docker playground disabled.
- Integrated Web API decoder and inventory panel: **11 tests / 2 files PASS**.
  `tsc --noEmit` and ESLint on those four production/test TS files PASS.

## Earlier evidence and remaining limits

`original-activity-red.log` is the preselection defect before repair: the actual
leaf reports `no_live_client` instead of `browser_lane_off`.
`original-blocked-build.log` retains the earlier inherited `runtime_toml.ml`
`let*` compile failure. The tool surface and full Runtime test were not executable
then. The published parent fixes that blocker; the current builds and executions
above supersede those unexecuted scopes. Old leaf/Web/browser evidence under
`2026-10-04-browser-lane-activity` remains an original-author historical snapshot.

Raw logs are preserved byte-for-byte, including compiler output, ANSI, and final
blank lines. `checks.json` pins source and artifact hashes. No live configuration,
real Browser session, full server bootstrap, native TUI/PTY, browser rerun, full
suite, CI, or deployment was performed. The server-installed activity observer
bridge remains source-reviewed; the focused tool tests inject the observer.
