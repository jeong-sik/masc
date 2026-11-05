; The writer zone of the authorization log, on the files that the real
; bootstrap writes in a temporary directory. Some cases start this executable
; again as a second process that holds a lock file.
;
; There is no (action ...) field: the default action of a test stanza runs the
; executable, and a stanza with an action sends the targeted CI runner down the
; alias path, where the whole build counts against the timeout of the suite.

(test
 (name test_authz_zone)
 (modules test_authz_zone)
 (libraries masc_test_deps))
