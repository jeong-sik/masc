(test
 (name test_oas_timeout_budget_strike)
 (modules test_oas_timeout_budget_strike)
 (libraries masc masc.keeper_failure_policy masc.keeper_runtime masc.runtime alcotest eio eio_main agent_sdk agent_sdk.llm_provider))
