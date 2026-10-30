; Not a test: prints how long the fleet stream (RFC-0477) takes from a hub
; change to the terminal client's view, over loopback, for several fleet sizes
; and subscriber counts. Run by hand from _build/default/test.

(executable
 (name bench_fleet_stream)
 (modules bench_fleet_stream)
 (libraries masc masc_server masc_tui_fleet_stream masc.http_client grpc-direct grpc-direct-core yojson eio eio.unix eio_main httpun gluten unix))
