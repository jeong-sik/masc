; The pump that serves one client of an SSE stream fed by a producer,
; with the fleet stream's frames: the Snapshot
; first, events in order, the keepalive frame is no event, a client
; that stops reading is closed at the queue bound, the response's answer ends
; the pump, each step, producers on several domains, and every
; way out removes the subscription.

(test
 (name test_server_sse_pump)
 (modules test_server_sse_pump)
 (libraries masc masc_server masc.sse_wire alcotest yojson eio eio.mock eio_main str))
