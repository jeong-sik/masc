# PR #40960 owned-parent publication response

Published base `2e34863666dde7dd334adb47dee397b81358f928`; this extends the earlier response tree `0147eb99c1c72913ae915c3237d9be59c40b96d4` after independent review found symlinked directory publication could return an unreadable address and write outside the store.

Actual RED: three new fixtures (canonical evidence directory, recovery directory, store root) each created a matching external file through a symlink. All **3 intended assertions failed**. Each fixture asserts both no external digest file and an explicit publication error, while cleanup unlinks the symlink before recursive temporary-directory cleanup. One initial fixture build used the reserved OCaml keyword `external`; its raw build failure is retained and corrected before runtime RED.

Repair: the existing recursive durable-directory constructor now uses `lstat` for root and descendant EEXIST checks. This shared writer path rejects symbolic directory components before atomic publication. In addition, fallback admission checks the canonical owned directory chain: a missing leaf below a symlinked parent does not authorize recovery publication. Existing permitted missing-canonical/directory-obstruction fallback behavior is preserved.

The first repair stopped external writes but one test still observed successful fallback under the invalid canonical parent (**34/35 PASS**). The final owned-chain check fixes that remaining case. Final focused wrapper build and full worker executable: **35 PASS in 6.591s**, using test/dune's declared environment. This includes all prior 32 cases, including earlier external-inode/canonical-failure fixes. Exact source, binary and raw artifact hashes are in `checks.json`. No full suite, production runtime, or concurrent malicious parent-swap proof is claimed.

Commands: `DUNE_JOBS=2 opam exec --switch=5.5.1 -- scripts/dune-local.sh build test/test_lane_addon_worker.exe`; RED selected `test lifecycle 0-2`, final all worker cases. Environment: empty MASC_BASE_PATH/ZAI_API_KEY/TYPESAFEAI_API_KEY and false MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED/MASC_KEEPER_DOCKER_PLAYGROUND.
