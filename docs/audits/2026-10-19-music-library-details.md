# Selected music project and take details

Issue #43897; Native Stack #43902 contains PRs #43900 and #43901 and targets
`feat/tui-music-entry`. This records selected-item inspection and display; it
does not claim that the broader music and nonmusic TUI work has finished or
that these stacks have reached main.

## Data and ownership

Listing a directory does not parse every project or take. Selecting one entry
starts its own worker, using the existing project decoder or capture validator.
Phrase details preserve the saved title, tempo, meter, duration and tracks.
Imported MIDI preserves independent pattern timing. Arrangement details are
document metadata and do not certify that every external asset is playable.
Take details validate the manifest, JSONL totals and WAV metadata and retain a
failed recording's outcome and reason. Invalid data remains a source error.

Moving away retires the old selection, requests worker cancellation and joins
its actual exit before starting the replacement. Intermediate selections can
be superseded without spawning another worker. Late results cannot replace the
current details. Opening an editor retains the selected path and waits for
inspection cleanup before handing over input. Library close also joins the
active worker. A result message and worker exit are separate observations.

The installer includes both new worker modules in its immutable runtime.

## Executed checks and manual observation

At functional head `db1d68e559995971b8c893ef4fcaa5d73c3c79e8`:

```sh
cd tools/alphatex
node --test test/music-workbench.test.mjs test/music-library-info.test.mjs \
  test/sequencer-close.test.mjs test/arrangement-close.test.mjs
```

24 tests passed, none failed or skipped. These cover real saved documents and
capture files, the actual worker, malformed data, immediate cancellation,
superseded results, joining cleanup and literal selected paths. They inspect
requests, saved state and ownership; no screen wording or layout test was added.
Independent reviewers reported source PASS for the reader at
`4d9fd195fec1ac44ac0e29ff201448f33d958c3a` and UI integration at
`db1d68e559995971b8c893ef4fcaa5d73c3c79e8`.

A separate-prefix installation completed successfully, with runtime digest
`cb8d2b25b0d3c968bfbbb46bb6f0a8445d1473825a61509f37439c344f1f3e07`.
Its real terminal showed the saved title `Continued from the music library`,
100 BPM, 4/4, 9.60 seconds and one note for an opaque project filename. Refresh
retained selection. Selecting malformed JSON showed its source failure, and
moving back restored valid details. Exiting closed the owned terminal process.
The saved document remained byte-identical, SHA256
`559b82f2256593af1aeb25858c012ed72320239ba3301e1d7485734f27141de7`.
The operator's installed helper was not replaced.

## Predecessor MASC entry proof

The explicitly requested native artifact run
https://github.com/jeong-sik/masc/actions/runs/39196423942 completed successfully.
Its receipt binds source `201941f220b53022ca02dee64648c95b225aebbe`, workflow
`6869ba3f24cf3694cc09180a4df9bcdfa408e5a7` and binary SHA256
`5b26c3d68f1372086e0cbe6e287a87213b03c278de1c616e1eb0bb8971a3d586`.
It built the native TUI and ran `test_tui_detail_reading`,
`test_tui_board_successor` and `test_tui_usage_scope`. This is focused evidence,
not full release CI or tests of the new JavaScript details worker.

That downloaded executable's `--build-commit` and SHA256 matched the receipt.
In its own terminal, connected to the live workspace, Dashboard `s` opened the
music library with the correct `.masc/music/projects` and `sessions` roots.
A new phrase accepted C4 and the title `MASC terminal round trip`; `q` saved
one note and returned to the library, and another `q` restored Dashboard.
In music-sensei chat, `/music` opened the same library without graphics support.
The server remained the separately deployed older build. The downloaded
executable remained separate from the operator's installed MASC binary. Its
native CI receipt does not cover the later JavaScript details worker.

A subsequent manual pairing is recorded in `verification.json.native_pairing`:
native source `201941f220b53022ca02dee64648c95b225aebbe` used companion source
`db1d68e559995971b8c893ef4fcaa5d73c3c79e8` with installed payload
`cb8d2b25b0d3c968bfbbb46bb6f0a8445d1473825a61509f37439c344f1f3e07`.
The recorded Dashboard `s` entry led to the capture
`04-native-selected-phrase.txt`, which shows `MASC terminal round trip`, 100 BPM,
4/4, 9.60 seconds and one note under the live workspace's music roots. Exiting
returned to Dashboard, retained in `05-native-returned-dashboard.txt`.

The separate native entry audition also retained an unsent chat draft through
Keeper detail, Dashboard, the music library and return to music-sensei chat.
Its `verification.json.draft_round_trip` records the original and returned
captures. The first numeric-tab attempt remained in Keeper detail and was not
counted as music entry; Escape to the list and then Dashboard preceded the
successful handoff. The draft was cleared afterward without submitting it.
This used the earlier companion payload, so it proves parent MASC draft
retention and does not extend the new worker's CI coverage.
