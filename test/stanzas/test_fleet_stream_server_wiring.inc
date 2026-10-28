; The server tells the fleet stream hub what every scan found (RFC-0477): a
; readable fleet section becomes a reading. A scan that failed or timed out, and
; a section that failed, timed out or cannot be read, become an outage. A
; section still warming up tells the hub nothing.

(test
 (name test_fleet_stream_server_wiring)
 (modules test_fleet_stream_server_wiring)
 (libraries masc masc_server alcotest yojson eio eio_main))
