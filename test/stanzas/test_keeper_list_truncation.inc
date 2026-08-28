; MASC_EXEC_ALLOW_LOCAL_PLAYGROUND: the keeper list fixtures create keepers
; whose sandbox_profile resolves to Local (incidental — the suite measures
; list truncation/axis projection, not sandbox isolation), and keeper-up
; validation now rejects Local fail-closed without the hatch.
(test
 (name test_keeper_list_truncation)
 (modules test_keeper_list_truncation)
 (action
  (setenv
   MASC_EXEC_ALLOW_LOCAL_PLAYGROUND
   true
   (run %{test})))
 (libraries masc_test_deps))
