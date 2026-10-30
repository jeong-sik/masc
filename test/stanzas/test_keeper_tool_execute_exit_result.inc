; The two cases run a real command under the profile
; Masc_test_deps.fixture_sandbox_profile picks, through the turn sandbox
; factory the suites share. That starts a persistent container, which the
; test isolation guard refuses unless the lane says it wants the real daemon
; (MASC_TEST_ALLOW_REAL_DOCKER=1, set by the full CI lane next to the image
; it builds). Elsewhere the suite fails with that guard's message; it does
; not skip.
(test
 (name test_keeper_tool_execute_exit_result)
 (modules test_keeper_tool_execute_exit_result)
 (libraries masc masc_test_deps alcotest yojson unix))
