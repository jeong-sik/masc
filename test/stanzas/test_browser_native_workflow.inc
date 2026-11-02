(test
 (name test_browser_native_workflow)
 (modules test_browser_native_workflow)
 (libraries masc masc.browser_lane alcotest yojson unix)
 (deps test_browser_ego_workflow_window.cjs
  ../lib/browser_ego_raw_type.ml ../lib/browser_ego_workflow.ml))

(rule
 (alias runtest-test_browser_ego_workflow)
 (deps test_browser_ego_workflow.cjs ../lib/browser_ego_workflow.ml)
 (action (run node %{dep:test_browser_ego_workflow.cjs})))

(alias
 (name runtest)
 (deps (alias runtest-test_browser_ego_workflow)))

(rule
 (alias runtest-test_browser_ego_popup)
 (deps test_browser_ego_popup.cjs ../lib/browser_ego_workflow.ml)
 (action (run node %{dep:test_browser_ego_popup.cjs})))

(alias
 (name runtest)
 (deps (alias runtest-test_browser_ego_popup)))

(test
 (name test_browser_ego_native_window)
 (modules test_browser_ego_native_window)
 (libraries masc alcotest yojson))

(test
 (name test_browser_ego_raw_type)
 (modules test_browser_ego_raw_type)
 (libraries masc alcotest yojson unix str)
 (deps test_browser_ego_raw_type.cjs))
