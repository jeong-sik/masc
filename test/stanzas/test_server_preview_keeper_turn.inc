; One turn of a person's Keeper in the localhost preview (plan D2-8), over a
; zone on real files whose records the real writers made, a runtime.toml with
; a login receipt of each account, and a Claude Code CLI played by a python3
; script. The access is published once per process, so the executable holds
; one case.
; It lists its libraries without masc_test_deps: an executable that links
; masc_test_deps publishes the single-user access when it starts.
;
; There is no (action ...) field: the default action of a test stanza runs the
; executable, and a stanza with an action sends the targeted CI runner down the
; alias path, where the whole build counts against the timeout of the suite.

(test
 (name test_server_preview_keeper_turn)
 (modules test_server_preview_keeper_turn)
 (libraries
  alcotest
  eio
  eio_main
  httpun
  masc
  masc.auth
  masc.config_dir_resolver
  masc.fs_compat
  masc.masc_core
  masc.runtime
  masc.server
  unix
  yojson))
