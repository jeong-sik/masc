; The server volume sweep records and reports observations without scheduling
; repair when cross-workspace ownership is unverified.
(test
 (name test_server_keeper_volume_maintenance)
 (modules test_server_keeper_volume_maintenance)
 (libraries alcotest astring eio masc masc.server yojson))
