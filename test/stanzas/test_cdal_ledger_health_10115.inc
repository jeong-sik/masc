; #10115: dedicated stanza so MASC_BASE_PATH is set BEFORE the
; test executable loads. Same rationale as #10091/#10097/#10101.

(test
 (name test_cdal_ledger_health_10115)
 (modules test_cdal_ledger_health_10115)
 (action
  (setenv MASC_BASE_PATH /tmp/test-cdal-ledger-health-10115
   (setenv MASC_BASE_PATH_INPUT /tmp/test-cdal-ledger-health-10115
    (run %{test}))))
 (libraries masc_test_deps))
