(test
 (name test_keeper_supervisor_observability_10125)
 (modules test_keeper_supervisor_observability_10125)
 (action
  (setenv MASC_BASE_PATH /tmp/test-keeper-supervisor-obs-10125
   (run %{test})))
 (libraries masc_mcp alcotest unix))
