; Whether a CLI may start on an account after the accounts were turned off,
; over real files: the bootstrap, one person whose records the real writers
; made, and an Off that the local operator commits. The access is published
; once per process, so the executable holds one case. It lists its libraries
; without masc_test_deps: an executable that links masc_test_deps publishes
; the single-user access when it starts.
;
; There is no (action ...) field: the default action of a test stanza runs the
; executable, and a stanza with an action sends the targeted CI runner down the
; alias path, where the whole build counts against the timeout of the suite.

(test
 (name test_runtime_account_access_off)
 (modules test_runtime_account_access_off)
 (libraries alcotest eio_main masc.auth masc.fs_compat masc.masc_core masc.runtime unix))
