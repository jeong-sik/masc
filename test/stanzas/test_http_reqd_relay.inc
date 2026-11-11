; A request handled on another domain than its connection: a real httpun
; connection on a second domain, its handler on the owner domain (RFC
; http-transport-runs-on-its-own-domain §3.3).

(test
 (name test_http_reqd_relay)
 (modules test_http_reqd_relay)
 (flags (:standard -open Masc))
 (libraries masc masc.masc_eio_context alcotest eio eio.unix eio_main httpun httpun-eio gluten))
