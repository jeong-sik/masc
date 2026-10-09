# Gate decision projection evidence

PR #42091, base 586399b66f832c377a4f5ef1dcf37cda439aefc4.
Code head b0c745ba3c38e2227966af188a1a26dd9a91b657.

Focused command `opam exec -- dune build test/test_keeper_gate_replay.exe test/test_keeper_gate_auto_judge_labels.exe` completed exit 0 after correcting the private interface from exact_attempt_error to exact_attempt_rejection. The first attempt failed at that interface; it is not counted as success.

Existing labels executable: 4 PASS, run Y149HDXY.
Replay executable `test dispatch 0-1 --color=never`: 2 PASS, run ZFYW2GUG.
Replay executable `test dispatch 7-8 --color=never`: 2 PASS, run XYOK3PA1.
Other replay cases were deliberately not run. No provider or live runtime was contacted.

Public keeper_gate.mli is byte-identical to the base. Removing only the seven extracted blocks and new direct bindings from the compared roots gives an identical retained authority/effect body. All extracted implementations retain their bodies. Root 2386 -> 2031 lines. This is a partial responsibility split, not campaign completion or a performance improvement.

Dune marks the canonical types and projection modules private. The public Gate interface remains the admission boundary; no compatibility reader or new public test API was added. No CI, installation, runtime, formal GitHub approval or merge is claimed.
