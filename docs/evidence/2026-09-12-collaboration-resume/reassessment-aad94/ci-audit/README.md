# Current CI reassessment — 2026-09-12

Read-only snapshot; no builds, fixes, pushes, dispatches, or wait/poll loops. Constitution read in full. JSON files preserve actual PR/run identity; failed-*.log files preserve failed job logs only.

## Installed candidate versus current PR

Installed runtime identity aad94bbf3fb90a4600496bf56d7590f02ff385ad is supplied by the parent runtime audit; this CI audit independently confirms exact-head Test 34697880885 SUCCESS and Release 34697882117 SUCCESS. Those successes do not certify current PR #35515 head 3d3c094ab7e83f8985c61a185f6a1052462ae16b, whose base is now main f04a08dc6e87d608c19becc44af8fe0ae3503956. The new head is a merge of aad94 and f04a08, with 144 files changed from installed aad94. No installation of 3d3c094 was performed here.

## PR #35515

Current PR check 34699111292: failed edited tests; lint, release @check, and dashboard typecheck succeeded.
- test_keeper_tool_definition_source: deferred summary first line of masc_fusion_status is 81 bytes and offered truncated (failed log lines 76-90).
- test_keeper_tool_schema_bytes: 108131 bytes across 124 tools versus ceiling 107631, +500 bytes (lines 102-118).
- Attribution: integration/feature contract failures, not infrastructure. Both Fusion TOML descriptions changed relative to current base. This audit did not independently calculate that those alone contribute all 500 bytes; do not assert that.
- Next: shorten truthful Fusion summaries; account for the actual schema delta and run both affected suites at the next CI boundary. Do not enlarge the ceiling merely to silence a test.

## PR #35532

Head e45362b582fa1d683c72f89d4843f2e6b84b6901; base feat/verification-pdf-inspection f7133fff50a889b4b3d0ab293e9ce38083ed991a.
Exact Test 34699728493 SUCCESS. PR check 34699728563 FAILURE:
- Own feature CI wiring: PR-check edited test runner lacks ffprobe and ffmpeg, so MP4 authority dispatch fails; 18/19 tests pass. test.yml received ffmpeg but pr-check.yml dependencies did not. Log lines 750-798.
- Parent/base determinism debt: runtime_official_client_tool.ml:51 Option.value text projection, present unchanged in parent f7133 (lines 249-254).
- Stale parent release truth: parent package 0.35.13 older than latest tag v0.35.14 (line 497).
- Release @check and dashboard typecheck succeeded. MP4 native Test is successful; PR is not fully green.
- Next: add ffmpeg to PR-check environment, then synchronize parent release/lint fix or integrate into current passing parent. Do not treat missing dependency as MP4 decoder logic failure.

## PR #35536

Head bc39fb61950a5e4b51b053240d4c5e38735bf718; base fix/fusion-durable-result-lookup 132f808e9325fe0d60959a33c4a5c9b927d99217.
PR check 34699949318 FAILURE:
- Own new test compilation: test/test_verification_collaboration_evidence.ml:46 post.Board.id inferred as Board.Sub_board_id.t, expected Board.Post_id.t, in both dev and release build (lines 732-738, 845-849). Add explicit Board.post parameter annotation.
- Own new determinism failure: lib/verification_collaboration_evidence.ml:62 comment_offset uses Json_util.get_int |> default 0 (lines 249-254). Read also finds equivalent comment_limit default. Missing optional value and malformed provided type must remain distinct; implement typed parsing rather than just an exemption comment.
- Dashboard typecheck succeeded.
- Exact Test 34699957943 observed in_progress with its Test step already failure; terminal run outcome not yet available. gh refused failed logs while running. No retry/poll performed; do not report final Test failure or success yet.
- Next: repair two own feature failures, including invalid pagination coverage, then one CI check at the finishing boundary.
