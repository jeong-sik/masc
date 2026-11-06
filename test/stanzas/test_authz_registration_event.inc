; The body of an allowlist record: its bytes, how it is read, and every way a
; body fails to be one. There is no (action ...) field, so the targeted CI
; runner builds the executable before the suite starts and only the run is
; under the timeout.

(test
 (name test_authz_registration_event)
 (modules test_authz_registration_event)
 (libraries masc_test_deps))
