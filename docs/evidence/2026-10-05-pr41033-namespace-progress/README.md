# Per-namespace sampling discovery progress

Baseline #41033 `5c087c0d21e348b6981fcd96da40b4cd262f7735`, parent #40991 `bee7a1045803579c4ec6fbb6a73b5c33700eed2d`, Native Stack #40961 position6/7. Comments4179367604 and4179532194 describe the same confirmed retry path.

Both namespace directions are exercised through public Store discovery/retry calls. One namespace is replaced with a symlink to an empty external fixture directory: enumeration rejects it regardless of UID, while the exact healthy request’s counterpart remains absent. Initial healthy recovery verifies original outcome bytes and retires its request marker. Reopening Store and retrying still rereads that completed history on the original product. Two meaningful RED cases fail expectedfalse/actualtrue. The first attempt’s cleanup followed the symlink and masked the assertion; the corrected scoped finally restores only this fixture’s namespace before the existing cleanup. That failed attempt is retained separately, not claimed as valid RED.

The repair retains the existing pending discovery cycle sentinel and adds durable completion checkpoints for each namespace under the same discovery lock. Checkpoints are published only after all namespace request markers are durable. An unfinished cycle skips its completed namespace after reopening; a fresh cycle validates/clears prior completion metadata before publishing its sentinel. The global sentinel retires only after both enumerations complete. Request writers, stable cross-process locks, both-journal recovery, canonical ownership checks and full query allowance are unchanged. Known metadata names are excluded from request-marker iteration; malformed progress remains a discovery error rather than being overwritten.

Final tests also prove a newly marked public write in the completed namespace is not hidden, and the incomplete namespace recovers its original outcome after directory repair. Existing Runtime fixtures verify maintenance dispatch, per-instance completion and malformed sibling behavior.

```sh
DUNE_JOBS=2 opam exec --switch=5.5.1 -- scripts/dune-local.sh build test/test_lane_addon_worker.exe test/test_lane_addon.exe
(cd test && DUNE_SOURCEROOT=<this-worktree> ../_build/default/test/test_lane_addon_worker.exe test lifecycle 2-3)
(cd test && DUNE_SOURCEROOT=<this-worktree> ../_build/default/test/test_lane_addon_worker.exe)
(cd test && DUNE_SOURCEROOT=<this-worktree> ../_build/default/test/test_lane_addon.exe)
```

Focused builds passed. Current worker result is **50/51**, with both new namespace cases passing; lifecycle26 `receipt projection reads shared outcome once` still fails the inherited aggregate-read-envelope gap, owned by descendant #41126. This patch does not import a descendant backward or claim that failure fixed. The Store read-budget/bounded-reader region and failing test function are byte-identical to baseline; their hashes are recorded. Runtime result is **25/25 PASS**. This is not an all-green Native Stack verdict; the eventual parent/descendant composition still needs its own qualification.

Eight raw logs remain byte-exact with source and both binary hashes. No provider dispatch, full repository suite, hosted CI, release result or TerminalBench was run. The separate #40991 preflight repair remains frozen outside this worktree; no publication occurred here.
