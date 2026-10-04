# Sampling recovery discovery lifecycle qualification

This qualifies the local #41033 pending-index response, not release or production behavior. Original pending-index checkpoint: `be11419be81d5aa238c55788c499399323505681`. The per-instance discovery and bounded-error response checkpoint is `db0e3350f0eb009c9baa66918e80025b01303277`; this candidate actually merges published canonical-parent helper `7edd8bf77a870400643976b6637d3594821eb075`.

Discovery completion is retained per validated instance ID. A malformed binding cannot repeatedly rescan another instance's completed history, and an instance first encountered later still receives discovery. Durable per-request markers and locks remain authoritative for incomplete work. Root path classification is inside bounded error protection. Compact recovery uses the parent's canonical ownership helper before selecting a fallback.

Two runtime lifecycle regressions actually failed on the original checkpoint: one malformed binding forced a healthy instance's completed history to be read again, and a later instance was never discovered. A separate symlink-parent loop threw outside the bounded public reader. Raw RED logs and baseline binary identities are retained without rewriting. The read detector deliberately corrupts an already-completed, unmarked journal after successful recovery; it proves that maintenance does not rescan completed history.

The response alone built successfully, then passed 25 runtime cases and 42 of 43 worker cases. After the real parent merge, the focused build passed and the full two focused executables produced **25/25 runtime PASS** and **48/49 worker PASS**. All new lifecycle/ELOOP and six incoming canonical-parent/relative-root regressions passed. The sole worker failure is the unchanged `receipt projection reads shared outcomes` aggregate read envelope assertion, a known lower query gap owned by #41126. It remains a failure here; no descendant implementation or weakened assertion is included.

The worker-test merge conflict retained both adjacent function and registration blocks. No production policy or public Store API was broadened. No full Dune suite, transport process, live provider, or release qualification was run.

Commands, from this worktree with opam switch 5.5.1:

```sh
DUNE_JOBS=2 opam exec --switch=5.5.1 -- scripts/dune-local.sh build test/test_lane_addon.exe test/test_lane_addon_worker.exe
MASC_BASE_PATH= ZAI_API_KEY= TYPESAFEAI_API_KEY= MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED=false MASC_KEEPER_DOCKER_PLAYGROUND=false DUNE_SOURCEROOT="$PWD" _build/default/test/test_lane_addon.exe
MASC_BASE_PATH= ZAI_API_KEY= TYPESAFEAI_API_KEY= MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED=false MASC_KEEPER_DOCKER_PLAYGROUND=false DUNE_SOURCEROOT="$PWD" _build/default/test/test_lane_addon_worker.exe
```

Integrated build handle 9667 exited 0; runtime handle 59898 exited 0 (25 cases, 8.417s); worker handle 25433 exited 1 (49 cases, 8.817s). Checks pin current source/binaries and exact raw logs, including failed intermediate qualification. Raw whitespace/EOF warnings are preserved. This evidence contains local fixture paths.
