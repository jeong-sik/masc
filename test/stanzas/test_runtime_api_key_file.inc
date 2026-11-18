; The key file of a key account on real files: its modes, that a generation is
; written once, and which files are not read. It lists its libraries without
; masc_test_deps, which it does not need.
;
; There is no (action ...) field: the default action of a test stanza runs the
; executable, and a stanza with an action sends the targeted CI runner down the
; alias path, where the whole build counts against the timeout of the suite.

(test
 (name test_runtime_api_key_file)
 (modules test_runtime_api_key_file)
 (libraries alcotest eio_main masc.auth masc.runtime unix))
