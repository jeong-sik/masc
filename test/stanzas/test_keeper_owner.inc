; MASC_EXEC_ALLOW_LOCAL_PLAYGROUND: an owner-operation fixture TOML seeds
; sandbox_profile = "local" (incidental — the suite measures owner
; actor/delegate operation semantics, not sandbox isolation), and keeper-up
; validation now rejects Local fail-closed without the hatch.
(test
 (name test_keeper_owner)
 (modules test_keeper_owner)
 (action
  (setenv
   MASC_EXEC_ALLOW_LOCAL_PLAYGROUND
   true
   (run %{test})))
 (libraries masc_test_deps))
