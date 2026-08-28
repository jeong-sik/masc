; MASC_EXEC_ALLOW_LOCAL_PLAYGROUND: the keeper meta fixtures carry no
; sandbox_profile, which resolves to Local (incidental — the suite measures
; compact recovery tool-surface behavior, not sandbox isolation), and
; dispatch now rejects Local fail-closed without the hatch.
(test
 (name test_keeper_compact_recovery_tool_surface)
 (modules test_keeper_compact_recovery_tool_surface)
 (action
  (setenv
   MASC_EXEC_ALLOW_LOCAL_PLAYGROUND
   true
   (run %{test})))
 (libraries masc_test_deps))
