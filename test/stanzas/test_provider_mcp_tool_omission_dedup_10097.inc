; #10097: dedicated stanza so MASC_BASE_PATH is set BEFORE the
; test executable loads — same reason as test_require_tool_use_
; violation_counter_10091 above.  See that stanza's comment.

(test
 (name test_provider_mcp_tool_omission_dedup_10097)
 (modules test_provider_mcp_tool_omission_dedup_10097)
 (action
  (setenv MASC_BASE_PATH /tmp/test-provider-mcp-tool-omission-dedup-10097
   (setenv MASC_BASE_PATH_INPUT /tmp/test-provider-mcp-tool-omission-dedup-10097
    (run %{test}))))
 (libraries masc_test_deps))
