; The allowlist that the registration records add up to: who may write which
; event, one open registration per identity, and how an admission spends one.
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_authz_registration_state)
 (modules test_authz_registration_state)
 (libraries masc_test_deps))
