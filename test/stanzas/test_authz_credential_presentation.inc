; Which credential a request presents in multi-account mode: one of each kind,
; none, several, and the ones that do not read. No files, clock, or network.
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_authz_credential_presentation)
 (modules test_authz_credential_presentation)
 (libraries masc_test_deps))
