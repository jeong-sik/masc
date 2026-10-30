; RFC play-link-for-the-shared-machine §2.4: issuing, listing and revoking
; invites against a real credential store in a temp workspace.

(test
 (name test_play_invite)
 (modules test_play_invite)
 (action (run %{test}))
 (libraries masc_test_deps))
