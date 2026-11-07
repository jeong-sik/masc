; The browser sessions that the session records add up to: who may write
; them, one session per id, a new sign-in that ends the old session, and the
; lifetime. There is no (action ...) field, so the targeted CI runner builds
; the executable before the suite starts and only the run is under the
; timeout.

(test
 (name test_authz_session_state)
 (modules test_authz_session_state)
 (libraries masc_test_deps masc.agent_core.digest))
