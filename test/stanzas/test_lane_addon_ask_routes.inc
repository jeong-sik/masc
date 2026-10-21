; The installation question routes (RFC operator-quiz §4.6) through the real
; lane add-on router and token auth.
(test
 (name test_lane_addon_ask_routes)
 (modules test_lane_addon_ask_routes)
 (libraries masc_test_deps alcotest yojson bigstringaf httpun str uri unix eio eio_main masc.masc_core masc.fs_compat masc.server))
