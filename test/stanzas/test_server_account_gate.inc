; The account gate reads the route inventory the router keeps and refuses a
; path it does not name. The cases assert the refusals, not only the allowed
; path: a gate that refuses nothing passes an allowed-path case.
;
; It lists its libraries without masc_test_deps: the gate is pure and no access
; needs publishing.

(test
 (name test_server_account_gate)
 (modules test_server_account_gate)
 (libraries alcotest httpun masc masc.masc_types masc.server yojson))
