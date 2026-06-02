(test
 (name test_phase2_self_preservation)
 (modules test_phase2_self_preservation)
 (action
  (setenv MASC_BASE_PATH /tmp/test-phase2
   (setenv MASC_BASE_PATH_INPUT /tmp/test-phase2
    (run %{test}))))
 (libraries masc_test_deps masc_mcp masc_mcp.config alcotest eio eio_main unix fs_compat))
