(test
 (name test_browser_bidi_peer)
 (modules test_browser_bidi_peer)
 (libraries masc masc.browser_lane masc.monotonic_deadline masc.string_util alcotest yojson eio eio_main cstruct ws-direct-eio unix))

(rule
 (alias runtest)
 (deps test_browser_pointer_feedback.cjs ../lib/browser_pointer_feedback.ml)
 (action (run node %{dep:test_browser_pointer_feedback.cjs})))
