; The server tells the fleet stream hub what every scan found (RFC-0477): a
; measured snapshot becomes a reading, a failed or timed-out scan becomes an
; outage, and a snapshot with no reading in it tells the hub nothing.

(test
 (name test_fleet_stream_server_wiring)
 (modules test_fleet_stream_server_wiring)
 (libraries masc masc_server alcotest yojson eio eio_main))
