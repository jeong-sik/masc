; E2 of RFC http-transport-runs-on-its-own-domain: a Serving route answers
; while the owner domain is blocked, through the ingress the HTTP/1.1
; listener runs.

(test
 (name test_http_ingress_serving_route)
 (modules test_http_ingress_serving_route)
 (libraries
  masc_test_deps
  masc.masc_eio_context
  alcotest
  eio
  eio.unix
  eio_main
  httpun
  httpun-eio
  gluten))
