; #9629: judge callers (Governance_judge, Operator_judge) added to
; the OAS bridge SSOT.  Dedicated stanza for the same MASC_BASE_PATH
; reason as #10094.

(test
 (name test_oas_bridge_judge_callers_9629)
 (modules test_oas_bridge_judge_callers_9629)
 (action
  (setenv MASC_BASE_PATH /tmp/test-oas-bridge-judge-callers-9629
   (setenv MASC_BASE_PATH_INPUT /tmp/test-oas-bridge-judge-callers-9629
    (run %{test}))))
 (libraries masc_test_deps))
