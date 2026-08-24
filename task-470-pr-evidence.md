task-470 verification evidence

The original implementation commit 317405ea0a4492ed06025cdac0391bb554880071 is superseded by the newer main implementation; duplicate PR #29717 is closed.

Merged implementation evidence:
- https://github.com/jeong-sik/masc/pull/29606 (MERGED): live keeper-chat rendering
- https://github.com/jeong-sik/masc/pull/29622 (MERGED): decoder exhaustiveness fixes
- https://github.com/jeong-sik/masc/pull/30028 (MERGED): arrival-order interleaving, live decoder/transcript and interrupt-state coverage

Current verification PR: https://github.com/jeong-sik/masc/pull/30173 (DRAFT)
Current verification HEAD: ca381a5c40f519b81533babc6099c7622bdf8202

Fresh evidence from the current main-based worktree:
- dune build @check: EXIT_CODE=0 (build-check.log)
- dune exec ./test/test_tui_decode.exe: Test Successful, 86 tests
- dune exec ./test/test_tui_keeper_chat_live.exe: Test Successful, 13 tests
- dune exec ./test/test_tui_keeper_chat_transcript.exe: Test Successful, 28 tests
- test/dune registers test_tui_decode and test_tui_keeper_chat_live; the old manual scripts/ci-run-focused-tests.sh allowlist was removed by main's consolidated Dune test group.
