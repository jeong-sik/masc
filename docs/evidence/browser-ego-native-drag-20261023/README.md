# ego native pointer drag evidence — 2026-10-23

Candidate helper was extracted from `lib/browser_ego_peer.ml` at commit
`ece17fb7f256efef9e53cac04ed91c427e4bbabc` and executed unchanged in a real ego
TaskSpace 7 on a synthetic pointer-driven card fixture. It is not an end-to-end
execution of the OCaml adapter or the installed MASC server.

The route was observed from page geometry: `(142,304)`, `(356,304)`, `(570,304)`,
`(570,304)`. The page recorded trusted pointer-down, three held moves, then
pointer-up with `buttons=0`. Its application state became `completed=true` and
“Dropped · native input verified”. The helper returned `{error:null,released:true}`.
`native-drag.json` contains the raw result; `native-drag.png` shows the landing.
The task space was finished successfully with no kept pages.

The round scripts document reproduction. Replace `<checkout>` and
`<evidence-directory>` with absolute paths, choose a fresh task name, and use
the returned space ID rather than the recorded `7` in the finish round. Run the
scripts through `ego-browser nodejs -e 'await import("file:///absolute/round-NN.mjs")'`.
Observe the first snapshot before running the drag round. The evidence concerns
native pointer dragging; it does not establish general HTML5 drop acceptance.

Source review and syntax checks do not establish native OCaml typechecking,
a full build, installed binary deployment or Zen extension behavior.

Helper SHA-256: `8475e5ca932d6c9092e249d738f0722ef3dab2d6bea695040152f6a5de29fcb3`.
