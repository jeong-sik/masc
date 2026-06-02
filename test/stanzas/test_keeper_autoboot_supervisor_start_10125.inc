(test
 (name test_keeper_autoboot_supervisor_start_10125)
 (modules test_keeper_autoboot_supervisor_start_10125)
 (action
  (setenv MASC_BASE_PATH /tmp/test-keeper-autoboot-sup-10125
   (run %{test})))
 (libraries masc_mcp alcotest unix))
