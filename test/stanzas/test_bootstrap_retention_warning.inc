; Pure boundary arithmetic; no workspace needed.

(test
 (name test_bootstrap_retention_warning)
 (modules test_bootstrap_retention_warning)
 (action (run %{test}))
 (libraries masc_test_deps))
