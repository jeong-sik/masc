; RFC play-link-for-the-shared-machine §2.4 through the real router: who may
; issue, what the answer carries, and that revoking frees the DOS controller.

(test
 (name test_play_invite_routes)
 (modules test_play_invite_routes)
 (action (run %{test}))
 (libraries masc.machine_configuration masc_test_deps alcotest yojson bigstringaf unix eio eio_main masc.masc_core masc.dos_lane masc.server))
