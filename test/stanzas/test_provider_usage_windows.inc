(test
 (name test_provider_usage_windows)
 (modules test_provider_usage_windows)
 (deps fixtures/claude-code-2.1.280-rate-limit-event.jsonl)
 (libraries alcotest masc masc_test_deps))
