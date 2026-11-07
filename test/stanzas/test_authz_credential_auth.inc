; PATs and Service credentials against the writer zone, on real files in
; temporary directories: a token that acts, a wrong secret, an expiry, a
; disabled principal, a revoke by another and by the owner, and the intents.
; No network. There is no (action ...) field, so the targeted CI runner builds
; the executable before the suite starts and only the run is under the timeout.

(test
 (name test_authz_credential_auth)
 (modules test_authz_credential_auth)
 (libraries masc_test_deps))
