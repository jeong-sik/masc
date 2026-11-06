; The identity key of a person and the body of an admission: what each
; accepts, its bytes, how it is read, and who may write an admission record.
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_authz_admission_event)
 (modules test_authz_admission_event)
 (libraries masc_test_deps))
