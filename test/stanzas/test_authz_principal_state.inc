; The principals that admission records add up to: what one admission makes,
; the order of its checks, and that a user id and an identity each name one
; principal. There is no (action ...) field, so the targeted CI runner builds
; the executable before the suite starts and only the run is under the timeout.

(test
 (name test_authz_principal_state)
 (modules test_authz_principal_state)
 (libraries masc_test_deps))
