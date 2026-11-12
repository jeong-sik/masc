; The account server of a multi-account installation (plan S1a): what its
; table may hold, and the server started on a real installation in a temporary
; directory and a loopback port. The access is published once per process, so
; one case serves, and the case whose boot stops does so before the publication.
; It lists its libraries without masc_test_deps: an executable that links
; masc_test_deps publishes the single-user access when it starts.
;
; There is no (action ...) field: the default action of a test stanza runs the
; executable, and a stanza with an action sends the targeted CI runner down the
; alias path, where the whole build counts against the timeout of the suite.

(test
 (name test_server_accounts)
 (modules test_server_accounts)
 (libraries
  alcotest
  bigstringaf
  eio
  eio.unix
  eio_main
  httpun
  masc
  masc.auth
  masc.fs_compat
  masc.masc_eio_context
  masc.masc_types
  masc.server
  masc.string_util
  masc.workspace_connection
  unix
  yojson))
