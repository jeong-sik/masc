; Pure string checks over the embedded recipe; no docker, no daemon.

(test
 (name test_sandbox_image_recipe)
 (modules test_sandbox_image_recipe)
 (action (run %{test}))
 (libraries alcotest masc.keeper_sandbox_image masc.config))
