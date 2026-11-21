; The body of the legacy attribution record: the bytes of the frozen inventory
; and of a claim, that it reads back what it wrote, and every way a body fails
; to be one. There is no (action ...) field, so the targeted CI runner builds
; the executable before the suite starts and only the run is under the timeout.

(test
 (name test_authz_legacy_event)
 (modules test_authz_legacy_event)
 (libraries masc_test_deps))
