; #10101: same rationale as #10091 / #10097 — Masc_mcp module
; init triggers #9903 prod-guard on HOME; setenv before exec.

(test
 (name test_tool_help_registry_shard_coverage_10101)
 (modules test_tool_help_registry_shard_coverage_10101)
 (action
  (setenv MASC_BASE_PATH /tmp/test-tool-help-registry-shard-coverage-10101
   (setenv MASC_BASE_PATH_INPUT /tmp/test-tool-help-registry-shard-coverage-10101
    (run %{test}))))
 (libraries masc_test_deps))
