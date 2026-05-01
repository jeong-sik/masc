; #10121: dedicated stanza so MASC_BASE_PATH is set BEFORE the
; test executable loads. Same rationale as #10091/#10097/#10101.

(test
 (name test_keeper_turn_livelock_10121)
 (modules test_keeper_turn_livelock_10121)
 (action
  (setenv MASC_BASE_PATH /tmp/test-keeper-turn-livelock-10121
   (setenv MASC_BASE_PATH_INPUT /tmp/test-keeper-turn-livelock-10121
    (run %{test}))))
 (libraries masc_test_deps))
