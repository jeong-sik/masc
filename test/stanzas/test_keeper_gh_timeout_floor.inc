; Ratchet for gh_min_timeout_sec (#8688). 41 gh_command_timed_out
; rejections on 2026-04-17/18 at timeout_sec=5. Floor must stay
; at/above network latency budget.

(test
 (name test_keeper_gh_timeout_floor)
 (modules test_keeper_gh_timeout_floor)
 (libraries masc_test_deps))
