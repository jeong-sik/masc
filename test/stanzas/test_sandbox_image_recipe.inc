; Pure string checks over the embedded recipe; no docker, no daemon. The
; recipe file is a dep so a pull request that edits only the recipe selects
; this suite.

(test
 (name test_sandbox_image_recipe)
 (modules test_sandbox_image_recipe)
 (deps %{workspace_root}/sandbox-images/base/Dockerfile)
 (action (run %{test}))
 (libraries alcotest masc.keeper_sandbox_image masc.config masc))
