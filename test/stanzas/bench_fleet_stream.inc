; Not a test: prints how long the fleet stream takes from a hub
; change to the terminal client's view, over loopback, for several fleet sizes
; and subscriber counts. Run by hand from _build/default/test.

(executable
 (name bench_fleet_stream)
 (modules bench_fleet_stream)
 (libraries masc masc_server masc.http_client grpc-direct yojson eio eio.unix eio_main httpun gluten unix))
