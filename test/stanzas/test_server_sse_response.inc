; Server_sse_response over a real loopback socket: a frame the
; socket takes is Written, a client that stops reading ends the response as
; Stalled, a frame waiting when the client goes away ends at the stall bound,
; a frame answered as the time runs out is Written, close ends every waiting
; send, the stall bound counts from each send, and a waiting send can be
; cancelled. A response nobody writes to keeps itself alive: once an interval,
; put off by a frame, as [idle] answers, at most an interval late on a clock
; set back, and never after its close.

(test
 (name test_server_sse_response)
 (modules test_server_sse_response)
 (libraries masc masc_server alcotest eio eio.mock eio_main httpun gluten cstruct bigstringaf))
