; The engine of a multi-account installation (RFC
; a-persons-keeper-runs-on-the-engine, S1): the account server starts it on the
; access it published, it comes up on that access, and a store it refuses ends
; the process. The access, the run registries and the persistence of the
; Keepers are set once per process, so each boot has a process of its own: one
; in this executable, one in a child of it. It lists its libraries without
; masc_test_deps: an executable that links masc_test_deps publishes the
; single-user access when it starts.
;
; There is no (action ...) field: the default action of a test stanza runs the
; executable, and a stanza with an action sends the targeted CI runner down the
; alias path, where the whole build counts against the timeout of the suite.

(test
 (name test_server_accounts_engine)
 (modules test_server_accounts_engine)
 (libraries
  alcotest
  eio
  eio.unix
  eio_main
  httpun
  masc
  masc.auth
  masc.config
  masc.config_dir_resolver
  masc.config_journal
  masc.crypto_rng
  masc.fs_compat
  masc.masc_core
  masc.masc_types
  masc.masc_workspace
  masc.runtime
  masc.server
  masc.time_compat
  unix
  yojson))
