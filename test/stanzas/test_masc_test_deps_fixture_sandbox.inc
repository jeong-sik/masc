; Pins the arbitration Masc_test_deps.with_fixture_sandbox applies between a
; case body's outcome and its sandbox teardown result. Pure: no daemon, no
; keeper, so it runs on every lane.
(test
 (name test_masc_test_deps_fixture_sandbox)
 (modules test_masc_test_deps_fixture_sandbox)
 (libraries masc_test_deps))
