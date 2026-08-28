; MASC_EXEC_ALLOW_LOCAL_PLAYGROUND: the direct_keepalive fixtures seed
; sandbox_profile = "local" (incidental — the suite measures the keepalive
; lifecycle, not sandbox isolation), and keeper-up validation now rejects
; Local fail-closed without the hatch.
(test
 (name test_heartbeat_integration)
 (modules test_heartbeat_integration)
 (action
  (setenv MASC_EXEC_ALLOW_LOCAL_PLAYGROUND true
   (setenv MASC_BASE_PATH /tmp/test-heartbeat-integ
    (setenv MASC_BASE_PATH_INPUT /tmp/test-heartbeat-integ
     (run %{test})))))
 (libraries masc_test_deps masc masc.config fs_compat alcotest eio eio_main unix))
