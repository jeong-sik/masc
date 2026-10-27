(test
 (name test_browser_ego_peer)
 (modules test_browser_ego_peer)
 (libraries masc masc.browser_lane masc.string_util alcotest yojson base64 unix))

(rule
 (alias runtest)
 (deps test_browser_ego_target.cjs ../lib/browser_ego_peer.ml)
 (action (run node %{dep:test_browser_ego_target.cjs})))

(rule
 (alias runtest)
 (deps test_browser_ego_upload.cjs ../lib/browser_ego_peer.ml)
 (action (run node %{dep:test_browser_ego_upload.cjs})))

(rule
 (alias runtest-test_browser_ego_native_input)
 (deps test_browser_ego_native_input.cjs ../lib/browser_ego_peer.ml)
 (action (run node --test %{dep:test_browser_ego_native_input.cjs})))

(rule
 (alias runtest-test_browser_ego_page_management)
 (deps test_browser_ego_page_management.cjs ../lib/browser_ego_peer.ml)
 (action (run node --test %{dep:test_browser_ego_page_management.cjs})))

(alias
 (name runtest)
 (deps
  (alias runtest-test_browser_ego_native_input)
  (alias runtest-test_browser_ego_page_management)))
