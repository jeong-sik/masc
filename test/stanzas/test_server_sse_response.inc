; Server_sse_response over a real loopback socket (RFC-0493 §6): a frame the
; socket takes is Written, a client that stops reading ends the response as
; Stalled, a frame waiting when the client goes away ends at the stall bound,
; a frame answered as the time runs out is Written, close ends every waiting
; send, the stall bound counts from each send, and a waiting send can be
; cancelled.

(test
 (name test_server_sse_response)
 (modules test_server_sse_response)
 (libraries masc_server alcotest eio eio.mock eio_main httpun gluten cstruct bigstringaf))
