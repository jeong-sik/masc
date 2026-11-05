; Server_sse_response over a real loopback socket (RFC-0493 §6): a frame the
; socket takes is Written, a client that stops reading ends the response as
; Stalled, a client that goes away while a frame waits ends it at the stall
; bound, close ends every waiting send, and a waiting send can be cancelled.

(test
 (name test_server_sse_response)
 (modules test_server_sse_response)
 (libraries masc_server alcotest eio eio_main httpun gluten cstruct))
