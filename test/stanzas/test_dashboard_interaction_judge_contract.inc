; Interaction Judge must not present prototype LLM judging as production-ready.

(test
 (name test_dashboard_interaction_judge_contract)
 (modules test_dashboard_interaction_judge_contract)
 (action
  (setenv MASC_BASE_PATH /tmp/test-dashboard-interaction-judge-contract
   (setenv MASC_BASE_PATH_INPUT /tmp/test-dashboard-interaction-judge-contract
    (run %{test}))))
 (libraries masc_test_deps))
