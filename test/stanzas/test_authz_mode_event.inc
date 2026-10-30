; The body of a mode event: its bytes, how it is read, and a record that carries
; it. There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_authz_mode_event)
 (modules test_authz_mode_event)
 (libraries masc_test_deps masc.agent_core.digest))
