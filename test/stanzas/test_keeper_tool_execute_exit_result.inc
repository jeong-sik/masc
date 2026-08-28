; MASC_EXEC_ALLOW_LOCAL_PLAYGROUND: the fixtures run the typed dispatch on a
; keeper meta whose sandbox_profile resolves to Local (incidental — the suite
; measures exit-status-as-result semantics, not sandbox isolation), and
; dispatch now rejects Local fail-closed without the hatch.
(test
 (name test_keeper_tool_execute_exit_result)
 (modules test_keeper_tool_execute_exit_result)
 (action
  (setenv
   MASC_EXEC_ALLOW_LOCAL_PLAYGROUND
   true
   (run %{test})))
 (libraries masc masc_test_deps alcotest yojson unix))
