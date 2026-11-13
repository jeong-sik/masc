; The body of a purge record: its bytes, how it reads back, the bytes the
; external store writes for the subject of its start, and the bodies that are
; not one. No files, clock, or network.
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_authz_purge_event)
 (modules test_authz_purge_event)
 (libraries masc_test_deps))
