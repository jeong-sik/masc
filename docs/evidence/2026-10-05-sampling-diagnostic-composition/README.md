# Diagnostic fallback on the composed sampling stack

Qualified commit `bded711a7352a6a5e510b7a0cedbad96efd3e64f` includes the #40966 diagnostic-retention fix and the current cold-recovery/receipt-query descendants. Focused Dune build and all 18 server sampling HTTP tests passed. This includes actual primary diagnostic storage failure followed by the healthy secondary response and durable final outcome.

Build: `opam exec --switch=5.5.1 -- env DUNE_JOBS=2 bash scripts/dune-local.sh build test/test_server_lane_addon_sampling.exe`.
Run from `test/`: `../_build/default/test/test_server_lane_addon_sampling.exe`, with MASC_BASE_PATH, ZAI_API_KEY and TYPESAFEAI_API_KEY empty, MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED=false, MASC_KEEPER_DOCKER_PLAYGROUND=false and DUNE_SOURCEROOT set to this isolated worktree root.

Raw output is preserved byte-for-byte. Checks record source, binary and raw log hashes. The earlier 115-case result remains evidence for its own prior commit; it was not rerun here. No full suite, hosted CI, live provider, release or TerminalBench claim.
