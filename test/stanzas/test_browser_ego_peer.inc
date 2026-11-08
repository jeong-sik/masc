(test
 (name test_browser_ego_peer)
 (modules test_browser_ego_peer)
 (libraries masc masc.browser_lane masc.browser_configuration masc.string_util alcotest yojson base64 unix)
 (deps test_browser_ego_raw_type.cjs browser_ego_page_events_source.cjs ../lib/browser_ego_page_events.ml))

(test
 (name test_browser_ego_input_release)
 (modules test_browser_ego_input_release)
 (libraries masc alcotest))

(rule
 (alias runtest-test_browser_ego_target)
 (deps test_browser_ego_target.cjs ../lib/browser_ego_peer.ml)
 (action (run node %{dep:test_browser_ego_target.cjs})))

(rule
 (alias runtest-test_browser_ego_upload)
 (deps test_browser_ego_upload.cjs ../lib/browser_ego_peer.ml)
 (action (run node %{dep:test_browser_ego_upload.cjs})))

(rule
 (alias runtest-ego-takeover-js)
 (deps test_browser_ego_takeover.cjs ../lib/browser_ego_takeover.ml)
 (action (run node %{dep:test_browser_ego_takeover.cjs})))

(rule
 (alias runtest-test_browser_ego_native_input)
 (deps test_browser_ego_native_input.cjs ../lib/browser_ego_peer.ml)
 (action (run node --test %{dep:test_browser_ego_native_input.cjs})))

(rule
 (alias runtest-test_browser_ego_page_management)
 (deps test_browser_ego_page_management.cjs ../lib/browser_ego_peer.ml)
 (action (run node --test %{dep:test_browser_ego_page_management.cjs})))

(rule
 (alias runtest-ego-takeover-js)
 (deps test_browser_ego_takeover.cjs ../lib/browser_ego_takeover.ml)
 (action (run node %{dep:test_browser_ego_takeover.cjs})))

(rule
 (alias runtest-test_browser_ego_page_events)
 (deps test_browser_ego_page_events.cjs browser_ego_page_events_source.cjs ../lib/browser_ego_page_events.ml)
 (action (run node --test %{dep:test_browser_ego_page_events.cjs})))

(rule
 (alias runtest-test_browser_ego_console)
 (deps test_browser_ego_console.cjs browser_ego_page_events_source.cjs ../lib/browser_ego_page_events.ml
  browser_ego_console_source.cjs ../lib/browser_ego_console.ml)
 (action (run node --test %{dep:test_browser_ego_console.cjs})))

(rule
 (alias runtest-test_browser_ego_cookie_write)
 (deps test_browser_ego_cookie_write.cjs browser_ego_cookie_write_source.cjs ../lib/browser_ego_cookie_write.ml)
 (action (run node --test %{dep:test_browser_ego_cookie_write.cjs})))

(rule
 (alias runtest-test_browser_ego_recovery)
 (deps test_browser_ego_recovery.cjs ../lib/browser_ego_recovery.ml)
 (action (run node --test %{dep:test_browser_ego_recovery.cjs})))

(alias
 (name runtest)
 (deps
  (alias runtest-test_browser_ego_recovery)
  (alias runtest-test_browser_ego_page_events)
  (alias runtest-test_browser_ego_console)
  (alias runtest-test_browser_ego_cookie_write)
  (alias runtest-ego-takeover-js)
  (alias runtest-test_browser_ego_target)
  (alias runtest-test_browser_ego_upload)
  (alias runtest-test_browser_ego_native_input)
  (alias runtest-test_browser_ego_page_management)
  (alias runtest-ego-takeover-js)))
