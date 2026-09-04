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
 ; ast_grep and the lib tree so the guard below can read the source: the
 ; discarded render is invisible from behaviour -- the descriptions come out
 ; the same either way -- so only the call graph says it stayed gone.
 (deps
  (source_tree ../lib))
 (libraries ast_grep masc_test_deps))
