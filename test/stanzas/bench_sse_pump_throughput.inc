; Not a test: prints how many SSE frames per second one connection carries over
; loopback through Server_sse_pump, one waiting send per frame, a bare flush
; wait per frame, and a write that waits for nothing (RFC-0493 §1.4). Run by
; hand from _build/default/test.

(executable
 (name bench_sse_pump_throughput)
 (modules bench_sse_pump_throughput)
 (libraries masc masc_server eio eio_main httpun gluten cstruct unix))
