; #10113: dedicated stanza so MASC_BASE_PATH is set BEFORE the
; test executable loads. Same rationale as #10091/#10097/#10101.

(test
 (name test_anti_rationalization_gate2_advisory_10113)
 (modules test_anti_rationalization_gate2_advisory_10113)
 (action
  (setenv MASC_BASE_PATH /tmp/test-anti-rat-gate2-advisory-10113
   (setenv MASC_BASE_PATH_INPUT /tmp/test-anti-rat-gate2-advisory-10113
    (run %{test}))))
 (libraries masc_test_deps))
