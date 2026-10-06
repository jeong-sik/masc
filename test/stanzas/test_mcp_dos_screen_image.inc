; RFC play-link-for-the-shared-machine §2.7: an MCP caller of masc_dos_screen
; gets the frame as a PNG image item beside the text observation.

(test
 (name test_mcp_dos_screen_image)
 (modules test_mcp_dos_screen_image)
 (action (run %{test}))
 (libraries masc.machine_configuration masc_test_deps alcotest yojson unix eio eio_main base64 mirage-crypto-rng.unix masc.masc_core masc.dos_lane))
