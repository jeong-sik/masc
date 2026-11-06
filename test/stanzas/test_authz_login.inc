; The sign-in and the admission of a login against the writer zone, on real
; files in temporary directories: who signs in, who joins through an
; invitation, and what is refused without writing. No network.
;
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_authz_login)
 (modules test_authz_login)
 (libraries masc_test_deps))
