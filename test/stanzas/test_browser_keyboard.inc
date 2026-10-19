(test
 (name test_browser_keyboard)
 (modules test_browser_keyboard)
 (libraries masc masc.browser_lane alcotest yojson))

(rule
 (alias runtest-test_browser_keyboard_guard)
 (deps test_browser_keyboard_guard.cjs ../lib/browser_interaction.ml)
 (action (run node %{dep:test_browser_keyboard_guard.cjs})))

(alias
 (name runtest)
 (deps (alias runtest-test_browser_keyboard_guard)))
