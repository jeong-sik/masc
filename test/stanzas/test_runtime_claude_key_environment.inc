; The environment a Claude Code child gets on an API key read from a file. It
; lists its libraries without masc_test_deps, which it does not need.
;
; There is no (action ...) field: the default action of a test stanza runs the
; executable, and a stanza with an action sends the targeted CI runner down the
; alias path, where the whole build counts against the timeout of the suite.

(test
 (name test_runtime_claude_key_environment)
 (modules test_runtime_claude_key_environment)
 (libraries alcotest masc.runtime unix))
