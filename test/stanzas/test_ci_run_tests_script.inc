(test
 (name test_ci_run_tests_script)
 (modules test_ci_run_tests_script)
 (deps %{workspace_root}/scripts/ci-run-tests.sh)
 (libraries alcotest unix masc.string_util))
