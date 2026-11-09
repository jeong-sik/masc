(test
 (name test_browser_interaction)
 (modules test_browser_interaction)
 (libraries masc masc.browser_lane alcotest yojson))

(rule
 (alias runtest-test_browser_scene_resource)
 (deps test_browser_scene_resource.cjs
       ../lib/browser_scene_script.ml)
 (action (run node %{dep:test_browser_scene_resource.cjs})))

(alias
 (name runtest)
 (deps (alias runtest-test_browser_scene_resource)))
