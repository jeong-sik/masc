; RFC play-link-for-the-shared-machine stage 1: the Player role, the
; CanPlayMachine permission and the five DOS seat tools that require it.
; Pure checks over the role table and the tool catalog; no workspace.

(test
 (name test_play_role_permissions)
 (modules test_play_role_permissions)
 (action (run %{test}))
 (libraries masc_test_deps))
