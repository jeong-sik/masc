; Whether a CLI may start on an account, by the access a process published, on
; the real tool judgment of a temporary base path and a real capture of a
; temporary home. The access is published once per process, so the executable
; holds one case.
; It lists its libraries without masc_test_deps: an executable that links
; masc_test_deps publishes the single-user access when it starts.
;
; There is no (action ...) field: the default action of a test stanza runs the
; executable, and a stanza with an action sends the targeted CI runner down the
; alias path, where the whole build counts against the timeout of the suite.

(test
 (name test_runtime_account_access)
 (modules test_runtime_account_access)
 (libraries alcotest eio_main masc.auth masc.runtime unix))
