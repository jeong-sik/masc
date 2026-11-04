; The state that the records of the authorization log add up to: every pair of
; a mode state and a mode event, the kinds that no layer reads yet, and the log
; that the real Fresh_bootstrap writes.
;
; There is no (action ...) field: the default action of a test stanza runs the
; executable, and a stanza with an action sends the targeted CI runner down the
; alias path, where the whole build counts against the timeout of the suite.

(test
 (name test_authz_state)
 (modules test_authz_state)
 (libraries masc_test_deps))
