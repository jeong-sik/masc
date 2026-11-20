; The hub that turns fleet scans into events: what makes an event and
; what does not, outages, subscribers that raise, and several domains publishing
; while watchers connect and leave.

(test
 (name test_fleet_stream_hub)
 (modules test_fleet_stream_hub)
 (libraries masc alcotest yojson))
