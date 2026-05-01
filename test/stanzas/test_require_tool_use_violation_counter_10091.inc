; #10091: dedicated stanza so MASC_BASE_PATH is set BEFORE the
; test executable loads — the top-level Masc_mcp init includes
; [Cdal_verdict_gate.default_base_path] which triggers the #9903
; prod-guard when base_path resolves to the operator's HOME.

(test
 (name test_require_tool_use_violation_counter_10091)
 (modules test_require_tool_use_violation_counter_10091)
 (action
  (setenv MASC_BASE_PATH /tmp/test-require-tool-use-violation-counter-10091
   (setenv MASC_BASE_PATH_INPUT /tmp/test-require-tool-use-violation-counter-10091
    (run %{test}))))
 (libraries masc_test_deps))
