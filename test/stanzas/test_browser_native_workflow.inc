(test
 (name test_browser_native_workflow)
 (modules test_browser_native_workflow)
 (libraries masc masc.browser_lane alcotest yojson))

(rule
 (alias runtest-test_browser_ego_workflow)
 (deps test_browser_ego_workflow.cjs ../lib/browser_ego_workflow.ml)
 (action (run node %{dep:test_browser_ego_workflow.cjs})))

(alias
 (name runtest)
 (deps (alias runtest-test_browser_ego_workflow)))
