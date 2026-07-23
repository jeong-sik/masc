; RFC-0195 P0 — same MASC_BASE_PATH setenv as
; test_tool_help_registry_shard_coverage_10101 (module-init base-path
; prod-guard raises under HOME).

(test
 (name test_tool_help_metadata_rfc_0195)
 (modules test_tool_help_metadata_rfc_0195)
 (action
  (setenv MASC_BASE_PATH /tmp/test-tool-help-metadata-rfc-0195
   (setenv MASC_BASE_PATH_INPUT /tmp/test-tool-help-metadata-rfc-0195
    (run %{test}))))
 (libraries masc_test_deps))
