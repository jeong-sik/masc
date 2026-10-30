; The fleet stream over a real loopback socket (RFC-0477): the server's accept
; loop and the route's serve, the terminal's HTTP client and Masc_tui_fleet_stream.
; A reader follows the hub, a keepalive comment is not an event, and a reader
; recovers from a server restart with the new server's Snapshot.

(test
 (name test_fleet_stream_loopback)
 (modules test_fleet_stream_loopback)
 (libraries masc masc_server masc_tui_fleet_stream masc.http_client alcotest eio eio_main httpun gluten))
