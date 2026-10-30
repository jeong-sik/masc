; Pure decision over injected effects; no TTY, no PATH, no installed TUI.

(test
 (name test_front_door)
 (modules test_front_door)
 (action (run %{test}))
 (libraries alcotest masc_front_door))
