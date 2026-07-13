(test
 (name test_keeper_turn_attempt_observer)
 (modules test_keeper_turn_attempt_observer)
 (action
  (setenv MASC_BASE_PATH /tmp/test-keeper-turn-attempt-observer
   (setenv MASC_BASE_PATH_INPUT /tmp/test-keeper-turn-attempt-observer
    (run %{test}))))
 (libraries masc_test_deps))
