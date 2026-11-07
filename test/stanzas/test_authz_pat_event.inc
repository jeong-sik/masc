; The body of a scoped PAT record: its bytes, how it reads back, what equal
; tells apart, and the bodies that are not one. No files, clock, or network.
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_authz_pat_event)
 (modules test_authz_pat_event)
 (libraries masc_test_deps yojson))
