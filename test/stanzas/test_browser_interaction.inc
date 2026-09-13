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

(rule
 (alias runtest-test_browser_scene_resource)
 (deps test_browser_scene_resource.cjs
       ../connectors/browser/extension/background.js
       ../lib/browser_scene_script.ml)
 (action (run node %{dep:test_browser_scene_resource.cjs})))

(alias
 (name runtest)
 (deps (alias runtest-test_browser_scene_resource)))

(rule
 (alias runtest-test_browser_connection_extension)
 (deps test_browser_connection_extension.mjs
       ../connectors/browser/extension/background.js)
 (action (run node %{dep:test_browser_connection_extension.mjs})))

(alias
 (name runtest)
 (deps (alias runtest-test_browser_connection_extension)))

(rule
 (alias runtest-test_browser_navigation_readiness)
 (deps test_browser_navigation_readiness.cjs
       ../connectors/browser/extension/background.js)
 (action (run node --test %{dep:test_browser_navigation_readiness.cjs})))

(alias
 (name runtest)
 (deps (alias runtest-test_browser_navigation_readiness)))
