(test
 (name test_browser_bidi_peer)
 (modules test_browser_bidi_peer)
 (libraries masc masc.browser_lane masc.string_util alcotest yojson eio eio_main cstruct ws-direct-eio unix))
