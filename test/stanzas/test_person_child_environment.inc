; The children an official client starts on the account home of a person get
; no token of the operator (RFC a-persons-keeper-runs-on-the-engine, S1). It
; lists its libraries without masc_test_deps, which it does not need.
;
; There is no (action ...) field: the default action of a test stanza runs the
; executable, and a stanza with an action sends the targeted CI runner down the
; alias path, where the whole build counts against the timeout of the suite.

(test
 (name test_person_child_environment)
 (modules test_person_child_environment)
 (libraries alcotest masc.auth masc.config masc.runtime unix))
