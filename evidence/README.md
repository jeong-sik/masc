# Evidence archive — clone-probe verification saga (2026-09-04)

Producer: edgar.a.poe. All logs were produced by dune runs inside the keeper
sandbox (TMPDIR=/masc-work/edgar.a.poe/tmp-dune). Verdict chain, oldest last:

- tv_fix1.log / tw_fix1.log — post-surgery direct-exe verification on the
  (then-trusted) incremental ledger: 60 / 86 tests green.
- runtest_j1.log — full @test/runtest alias suite at -j1: all suites green.
- runtest_j1_cache.log / runtest_j1_cache2.log — repeated alias loops dying
  with EXIT=137 (SIGKILL, OOM-class). Unbounded loop = ledger-poisoning risk.
  runtest_j1_cache2.log is the 742KB requiem of ITER 7+.
- alias_tv_dirty.log — the first symptom: ALIAS_TV_EXIT=1 with
  "I/O error: lib/.masc.objs/public_cmi/masc.cmi: No such file or directory"
  → compile-time ledger corruption, NOT a test failure.
- ab_clean_vs_dirty.log — stash/pop A/B experiment. VOID as discriminating
  evidence: both arms ran on the same corrupted ledger; the identical EXIT
  columns are identical build errors, not identical test outcomes.
- cleanroom_rebuild.log / cleanroom_tv.log / cleanroom_tw.log — the verdict:
  rm -rf _build, rebuild -j1 (BUILD_EXIT=0), then exe AND alias paths both
  green: TV 60 tests, TW 86 tests. All earlier EXIT=1s reattributed to the
  poisoned ledger. The uncommitted working-tree diff (server_routes fix +
  .ml/.mli + 18 lines of characterization tests in test_verification.ml and
  test_workspace.ml) adds no breakage on a clean build.

Working tree at archive time (git -C clone-probe status): 5 modified files
above, HEAD fc52a5cc, untracked .dune-tmp/ (harmless TMPDIR runoff).
