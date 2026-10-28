; The pump that serves one client of the fleet stream (RFC-0477): the Snapshot
; first, events in order, a keepalive that never displaces an event, a client
; that stops reading is closed at the queue bound, and every way out removes
; the subscription.

(test
 (name test_fleet_stream_pump)
 (modules test_fleet_stream_pump)
 (libraries masc masc_server masc.sse_wire alcotest yojson eio eio.mock))
