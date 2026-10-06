; RFC play-link-for-the-shared-machine §2.9 through the real router: the
; loaded program's layout, and a button pressing its machine keys in turn.

(test
 (name test_play_pad_routes)
 (modules test_play_pad_routes)
 (action (run %{test}))
 (libraries masc.machine_configuration masc_test_deps alcotest yojson bigstringaf unix eio eio_main masc.masc_core masc.dos_lane masc.lane_activity masc.server))
