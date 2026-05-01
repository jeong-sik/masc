(test
 (name test_heartbeat_integration)
 (modules test_heartbeat_integration)
 (action
  (setenv MASC_BASE_PATH /tmp/test-heartbeat-integ
   (setenv MASC_BASE_PATH_INPUT /tmp/test-heartbeat-integ
    (run %{test}))))
 (libraries masc_test_deps masc_mcp masc_mcp.config fs_compat alcotest eio eio_main unix))
