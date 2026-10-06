; RFC play-link-for-the-shared-machine §2.7 through the real router: an
; invite's bearer reads the shared DOS machine's frame as a PNG.

(test
 (name test_play_screen)
 (modules test_play_screen)
 (action (run %{test}))
 (libraries masc.machine_configuration masc_test_deps alcotest bigstringaf unix eio eio_main masc.masc_core masc.dos_lane masc.server))
