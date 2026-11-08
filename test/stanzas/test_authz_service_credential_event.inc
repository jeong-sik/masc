; The body of a Service credential record: its bytes, how it reads back, what
; equal tells apart, and the bodies that are not one. No files, clock, or
; network. There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_authz_service_credential_event)
 (modules test_authz_service_credential_event)
 (libraries masc_test_deps))
