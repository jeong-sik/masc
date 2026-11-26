; The fleet stream over a real loopback socket: the server's accept
; loop and the route's serve, the HTTP client and [Masc.Fleet_stream.decode].
; A reader follows the hub, the response's keepalive comment is not an event, and a reader
; recovers from a server restart with the new server's Snapshot.

(test
 (name test_fleet_stream_loopback)
 (modules test_fleet_stream_loopback)
 (libraries masc masc_server masc.http_client alcotest eio eio_main eio.mock httpun gluten yojson))
