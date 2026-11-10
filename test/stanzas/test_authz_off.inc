; masc auth off on real files in temporary directories: the Off of an
; installation that the real activation made, and the installations it
; refuses without writing.
;
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_authz_off)
 (modules test_authz_off)
 (libraries masc_test_deps))
