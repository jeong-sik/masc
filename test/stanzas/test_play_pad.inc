; RFC play-link-for-the-shared-machine §2.9: pad buttons, strict layout
; files, and the workspace-then-builtin lookup.

(test
 (name test_play_pad)
 (modules test_play_pad)
 (action (run %{test}))
 (libraries masc_test_deps))
