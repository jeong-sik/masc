; The body of an authorization scope: its bytes, how it reads back, the labels
; of every effect and channel, and the bodies that are not a scope. No files,
; clock, or network. There is no (action ...) field, so the targeted CI runner
; builds the executable before the suite starts and only the run is under the
; timeout.

(test
 (name test_authz_scope_body)
 (modules test_authz_scope_body)
 (libraries masc_test_deps yojson))
