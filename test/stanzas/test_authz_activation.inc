; The host-local activation, on real files in temporary directories: the
; bootstrap and the first Admin invitation, and the installations it refuses
; without writing.
;
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_authz_activation)
 (modules test_authz_activation)
 (libraries masc_test_deps))
