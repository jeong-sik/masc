(test
 (name test_browser_interaction)
 (modules test_browser_interaction)
 (libraries masc masc.browser_lane alcotest))

(rule
 (alias runtest-test_browser_interact_extension)
 (deps test_browser_interact_extension.mjs
       ../connectors/browser/extension/background.js
       ../lib/browser_interaction.ml)
 (action (run node %{dep:test_browser_interact_extension.mjs})))

(alias
 (name runtest)
 (deps (alias runtest-test_browser_interact_extension)))
