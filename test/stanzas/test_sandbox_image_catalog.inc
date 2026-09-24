; The sandbox image catalog: parse and resolve. No daemon; the load case uses
; a temporary directory as its config root.

(test
 (name test_sandbox_image_catalog)
 (modules test_sandbox_image_catalog)
 (action (run %{test}))
 (libraries alcotest masc))
