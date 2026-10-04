# Native40961 sampling review composition

This candidate combines the #40991 preflight repair with #41033 durable per-namespace discovery progress and the existing #41126 bounded receipt reader. Each original PR head and repaired parent is an ancestor; no parent is retargeted. Independent source review checked all five changed source/test files, publication ordering, checkpoint durability, stable request locks and preservation of the descendant's read-budget behavior.

Actual composed source `7af4279cfcd317b6cf99d3f0b0c3f503ef50613b` passed focused build and both small executable suites: **worker 51/51 and Runtime 25/25**. This includes both namespace regressions, real stdio full-wire preflight cases, and the projection case that still failed at the lower #41033 layer. That lower 50/51 result remains recorded as measured; this combined result does not rewrite its history.

```sh
opam exec --switch=5.5.1 -- env DUNE_JOBS=2 bash scripts/dune-local.sh build test/test_lane_addon_worker.exe test/test_lane_addon.exe
(cd test && DUNE_SOURCEROOT=<this-worktree> ../_build/default/test/test_lane_addon_worker.exe)
(cd test && DUNE_SOURCEROOT=<this-worktree> ../_build/default/test/test_lane_addon.exe)
```

Source, both binaries and byte-exact raw logs are hashed in checks.json. This is local focused qualification of the stated composition, not a full repository run, provider run, hosted CI or release verdict. TerminalBench remains unrun.
