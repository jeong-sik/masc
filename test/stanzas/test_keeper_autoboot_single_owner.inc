(test
 (name test_keeper_autoboot_single_owner)
 (modules test_keeper_autoboot_single_owner)
 (libraries masc_test_deps)
 (action
  (setenv MASC_KEEPER_BOOTSTRAP_ENABLED true
   (run %{test}))))
