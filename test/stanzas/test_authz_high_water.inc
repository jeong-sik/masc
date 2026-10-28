; The judgments of the external high-water mark, on real chains of records and
; states built in memory. Two cases read a real log file in a temporary
; directory.
;
; There is no (action ...) field: the default action of a test stanza runs the
; executable, and a stanza with an action sends the targeted CI runner down the
; alias path, where the whole build counts against the timeout of the suite.

(test
 (name test_authz_high_water)
 (modules test_authz_high_water)
 (libraries masc_test_deps masc.agent_core.digest))
