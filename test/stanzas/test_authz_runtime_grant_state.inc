; The grants that the Runtime grant records add up to: what the grant state
; projects, that a grant id names one grant for good, and the queries by
; Runtime and by grantee. There is no (action ...) field, so the targeted CI
; runner builds the executable before the suite starts and only the run is
; under the timeout.

(test
 (name test_authz_runtime_grant_state)
 (modules test_authz_runtime_grant_state)
 (libraries masc_test_deps))
