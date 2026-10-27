; Pure table checks over in-memory facts; no workspace, no files.

(test
 (name test_authz_decision)
 (modules test_authz_decision)
 (action (run %{test}))
 (libraries masc_test_deps))
