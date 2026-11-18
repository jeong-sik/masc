; The files of a key account on real files: where they are made, that a
; removal takes the key before the home, and which stage a removal that
; stopped reports. It lists its libraries without masc_test_deps, which it
; does not need.
;
; There is no (action ...) field: the default action of a test stanza runs the
; executable, and a stanza with an action sends the targeted CI runner down the
; alias path, where the whole build counts against the timeout of the suite.

(test
 (name test_runtime_key_account_files)
 (modules test_runtime_key_account_files)
 (libraries alcotest eio_main masc.auth masc.runtime unix))
