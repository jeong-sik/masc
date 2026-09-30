# Candle appraisal current-head check

PR #40004 head `b630600336a060763356564a083c57c2b15b7c05`, PR check run [36654228217](https://github.com/jeong-sik/masc/actions/runs/36654228217): four required checks succeeded, `dune build @check` failed.

The seven-lane refusal contract repair is verified: `test_keeper_gate_effect_coverage` passed all 30 cases. The current failure is distinct: `test_keeper_lane_cli_oneshot` timed out after 300 seconds (exit 124), and the later Dune rule batch stopped at the remaining step budget after 124 seconds. The final counter is `ran 238, skipped 2`; this is not a complete feature success result. No Alcotest [FAIL] or [ERROR] assertion was reported in the retained step log. Timeout causes are not established by that absence.

A focused native Test run [36659093709](https://github.com/jeong-sik/masc/actions/runs/36659093709) was dispatched on the same branch for these two suites with EIO_BACKEND=posix to distinguish an isolated adapter hang from batch execution effects. It completed successfully on b630: gate-effect30/30 and official-client one-shot14/14 cases passed (2/2 suites), with one-shot finishing in24seconds. The isolated result does not establish why the earlier concurrent/default-backend run timed out and cannot turn that failed PR check into merge evidence.
