(test
 (name test_keeper_long_turn_9943)
 (modules test_keeper_long_turn_9943)
 (action
  (setenv MASC_BASE_PATH /tmp/test-keeper-long-turn-9943
   (run %{test})))
 (libraries masc_mcp alcotest unix))
