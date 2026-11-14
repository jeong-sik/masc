; What leaves the server for a HEAD request and for a 204: real httpun and h2
; connections in memory, routed through the router (RFC 9110 §9.3.2, §8.6,
; §15.5.6).

(test
 (name test_http_response_content)
 (modules test_http_response_content)
 (libraries masc alcotest h2 httpun bigstringaf masc.server masc.config eio eio_main))
