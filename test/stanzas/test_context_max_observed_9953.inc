; #9953: dedicated stanza so MASC_BASE_PATH is set BEFORE the
; test executable loads. Same rationale as #10091/#10097/#10101.

(test
 (name test_context_max_observed_9953)
 (modules test_context_max_observed_9953)
 (action
  (setenv MASC_BASE_PATH /tmp/test-context-max-observed-9953
   (setenv MASC_BASE_PATH_INPUT /tmp/test-context-max-observed-9953
    (run %{test}))))
 (libraries masc_test_deps))
