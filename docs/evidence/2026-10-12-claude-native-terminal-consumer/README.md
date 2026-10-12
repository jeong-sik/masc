# Claude terminal consumer correction

Original #42577 source head df570fd42aab4998631ff4f40d7baef1d423f9e4 remains
SOURCE HOLD: Turn_finished still consumed native map values as int after they
became Native_block_open index / Native_block_closed. Its four-arm probe omitted
this consumer. Preserve that review and its evidence limits.

Correction extracts only open (identity,index) pairs, retires each identity to
Closed before publishing stops, and preserves existing closed tombstones.
No Hashtbl mutation during its fold; the collected list owns subsequent updates.
This avoids reopening a completed native identity after Turn_finished replay.

Extended direct probe /tmp/masc-claude-native-replay-20261012/generate.py includes
actual native terminal sweep along with selected start/progress/finish arms.
Parent pre-change exit2: completed identity reopened or renotified.
Held original head exit2: native_block_state list incompatible with int list
at List.sort_uniq Int.compare unfinished_native.
Corrected current exit0: previous four sequences plus start/Turn_finished/replayed
start/late progress/completion and finish-before-start/Turn_finished/start pass.
This interpreter typechecked the selected production portions together; it did
not typecheck the full callback/module or execute provider/bridge/reducer.
Minimal event declarations and callback container; rawtrace sink/no-op and
identity Eio.Cancel.protect substitute remain explicit probe limitations.
No full typecheck, build, CI, runtime, UI, installation or formal approval proof.
Production syntax-only parsing and diff check pass. Original HOLD requires
composite independent review before any acceptance claim.
