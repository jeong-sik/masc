; The body of a revocation of an Admin assignment: its bytes, how it is read,
; and who may write the record. There is no (action ...) field, so the targeted
; CI runner builds the executable before the suite starts and only the run is
; under the timeout.

(test
 (name test_authz_admin_event)
 (modules test_authz_admin_event)
 (libraries masc_test_deps))
