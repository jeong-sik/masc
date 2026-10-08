# Pure schedule decoding outside the TUI loader

Parent: `089327606d88bd81f26e193a4fcdbdda55be9560` (#41955).
Campaign: [#41857](https://github.com/jeong-sik/masc/issues/41857).

The 2,047-line loader mixed local store loading, HTTP acquisition and schedule
wire projection. Its actor/row/snapshot/wake readers now belong to the pure
`Masc_tui_schedule_decode` module. Only snapshot and exact wake-history entrypoints
are exposed; helpers are private. The three loader consumers call those
entrypoints directly after fetching, without forwarding aliases.

Moved function bodies match the parent exactly after the two exported binding
names are changed and the module imports/Result binding are supplied locally.
Read uncertainty, null-versus-false evidence, order, hold provenance, actor/wake
vocabularies and existing refusal text are preserved. No wire or stored fields
are added. The loader is now 1,668 lines. Its remaining responsibilities still
require semantic review; dropping below the inventory threshold does not remove
this initial candidate from the campaign.

## Executed evidence

[checks.json](checks.json) records the current binary, commands, exits and scope.
[source-sha256.json](source-sha256.json) fingerprints the changed source and
existing scenario owners.

| Direct consumer | Actual check | Result |
| --- | --- | --- |
| Main TUI's fleet/target/history loader calls | Focused executable build / [build.log](build.log) | exit 0 |
| Exact wake lookup, unavailable store and HTTP refusal | Existing `test_tui_schedule_wake_error_once.py` / [wake.log](wake.log) | 2 real PTY scenarios passed |
| Keeper-targeted schedule loader, HTTP/decode failures | Existing `test_tui_keeper_schedule_error_once.py` / [keeper.log](keeper.log) | 2 real PTY scenarios passed |
| Empty valid schedule snapshot | Existing `test_tui_schedules_empty_row_names_its_key.py` / [empty.log](empty.log) | 1 real PTY scenario passed |

The existing PTY assertions read actual rendered frames. No new source-shape
regression suite or mirrored parser test is added for a behavior-preserving
move. These are local fixtures, not live schedules. No full build, full CI,
physical terminal screenshot, installation, deployment, approval or merge is
claimed. Independent current-head source review is required for this slice.
