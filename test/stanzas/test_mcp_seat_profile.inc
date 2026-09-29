; RFC play-link-for-the-shared-machine §2.7: the seat door /mcp/play admits an
; invite's Player credential and answers the handshake and the CanPlayMachine
; tools only.

(test
 (name test_mcp_seat_profile)
 (modules test_mcp_seat_profile)
 (action (run %{test}))
 (libraries masc_test_deps alcotest yojson unix eio eio_main httpun mirage-crypto-rng.unix masc.masc_core masc.server masc.dos_lane))
