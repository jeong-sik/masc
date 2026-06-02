(test
 (name test_keeper_personality_round_trip)
 (modules test_keeper_personality_round_trip)
 (action
  (setenv MASC_BASE_PATH /tmp/test-keeper-personality-round-trip
   (setenv MASC_BASE_PATH_INPUT /tmp/test-keeper-personality-round-trip
    (run %{test}))))
 (libraries masc_test_deps))
