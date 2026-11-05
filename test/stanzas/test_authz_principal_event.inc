; The body of a principal record (disabled, enabled, deleted): its bytes, how it
; is read, and who may write the record. There is no (action ...) field, so the
; targeted CI runner builds the executable before the suite starts and only the
; run is under the timeout.

(test
 (name test_authz_principal_event)
 (modules test_authz_principal_event)
 (libraries masc_test_deps))
