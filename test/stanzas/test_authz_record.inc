; Pure checks over one record of the authorization log; no workspace, no files.
; There is no (action ...) field: the default action of a test stanza runs the
; executable, and a stanza with an action sends the targeted CI runner down the
; alias path, where the whole build counts against the timeout of the suite.

(test
 (name test_authz_record)
 (modules test_authz_record)
 (libraries masc_test_deps masc.agent_core.digest))
