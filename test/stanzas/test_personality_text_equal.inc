(test
 (name test_personality_text_equal)
 (modules test_personality_text_equal)
 (action
  (setenv MASC_BASE_PATH /tmp/test-personality-text-equal
   (setenv MASC_BASE_PATH_INPUT /tmp/test-personality-text-equal
    (run %{test}))))
 (libraries masc_test_deps))
