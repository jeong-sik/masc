; #10094: dedicated stanza so MASC_BASE_PATH is set BEFORE the
; test executable loads.  Same rationale as #10091/#10097/#10101.

(test
 (name test_oas_bridge_timeout_ssot_10094)
 (modules test_oas_bridge_timeout_ssot_10094)
 (action
  (setenv MASC_BASE_PATH /tmp/test-oas-bridge-timeout-ssot-10094
   (setenv MASC_BASE_PATH_INPUT /tmp/test-oas-bridge-timeout-ssot-10094
    (run %{test}))))
 (libraries masc_test_deps))
