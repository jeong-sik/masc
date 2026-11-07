; The body of a browser session record: its bytes, how it is read, and the
; digest of a session secret. There is no (action ...) field, so the targeted
; CI runner builds the executable before the suite starts and only the run is
; under the timeout.

(test
 (name test_authz_session_event)
 (modules test_authz_session_event)
 (libraries masc_test_deps masc.agent_core.digest))
