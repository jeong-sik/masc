; RFC play-link-for-the-shared-machine §2.6 through the real router: the
; play page is public and self-contained, and the seat names the bearer,
; the DOS controller and whom it can be handed to.

(test
 (name test_play_page)
 (modules test_play_page)
 (action (run %{test}))
 (libraries masc_test_deps alcotest yojson bigstringaf unix eio eio_main masc.masc_core masc.dos_lane masc.server))
