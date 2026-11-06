; The body of a revocation cancel: its bytes, that its subject has the bytes of
; the external store, and how it is read. There is no (action ...) field, so the
; targeted CI runner builds the executable before the suite starts and only the
; run is under the timeout.

(test
 (name test_authz_cancel_event)
 (modules test_authz_cancel_event)
 (libraries masc_test_deps))
