(test
 (name test_browser_native_workflow)
 (modules test_browser_native_workflow)
 (libraries masc masc.browser_lane alcotest yojson))

(rule
 (alias runtest)
 (deps test_browser_ego_workflow.cjs ../lib/browser_ego_workflow.ml)
 (action (run node %{dep:test_browser_ego_workflow.cjs})))
