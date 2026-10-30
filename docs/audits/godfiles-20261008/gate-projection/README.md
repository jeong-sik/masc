# Gate decision projection evidence

PR #42091.

Focused command `opam exec -- dune build test/test_keeper_gate_replay.exe test/test_keeper_gate_auto_judge_labels.exe` completed exit 0.

Existing labels executable: 4 PASS, run LDAHXQ0L.
Replay executable `test dispatch 0-1 --color=never`: 2 PASS, run VQC21T8M.
Replay executable `test dispatch 7-8 --color=never`: 2 PASS, run V2JR2Y6R.
Other replay cases were deliberately not run. No provider or live runtime was contacted.

Public keeper_gate.mli is byte-identical to the base. Removing only the seven extracted blocks and new direct bindings from the compared roots gives an identical retained authority/effect body. All extracted implementations retain their bodies. Root 2386 -> 2031 lines. This is a partial responsibility split, not campaign completion or a performance improvement.

Dune marks the canonical types and projection modules private. The public Gate interface remains the admission boundary; no compatibility reader or new public test API was added. No CI, installation, runtime, formal GitHub approval or merge is claimed.
