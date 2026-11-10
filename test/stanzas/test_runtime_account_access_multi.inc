; Whether a CLI may start on an account in a multi-account process, over a zone
; on real files with two persons whose records the real writers made. The
; access is published once per process, so the executable holds one case.
; It lists its libraries without masc_test_deps: an executable that links
; masc_test_deps publishes the single-user access when it starts.
;
; There is no (action ...) field: the default action of a test stanza runs the
; executable, and a stanza with an action sends the targeted CI runner down the
; alias path, where the whole build counts against the timeout of the suite.

(test
 (name test_runtime_account_access_multi)
 (modules test_runtime_account_access_multi)
 (libraries
  alcotest
  eio_main
  masc.agent_core.llm_provider
  masc.auth
  masc.fs_compat
  masc.runtime
  unix))
