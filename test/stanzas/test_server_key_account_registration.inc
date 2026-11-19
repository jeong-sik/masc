; The registration of a person's API key (RFC
; a-persons-api-key-is-their-own-provider-account 3.3), through the answers
; of its route, over a zone on real files and a runtime.toml the server
; reads.
; It lists its libraries without masc_test_deps: an executable that links
; masc_test_deps publishes the single-user access when it starts.

(test
 (name test_server_key_account_registration)
 (modules test_server_key_account_registration)
 (libraries
  alcotest
  eio
  eio.unix
  eio_main
  masc.auth
  masc.masc_log
  masc.runtime
  masc.server
  masc.string_util
  unix
  yojson))
