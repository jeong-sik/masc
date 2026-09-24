; The sandbox image catalog: parse, resolve, change and save. No daemon; the
; load cases use a temporary config root. The shipped catalog and the recipe
; directories are deps so the suite can check they name the same images.

(test
 (name test_sandbox_image_catalog)
 (modules test_sandbox_image_catalog)
 (flags (:standard -open Masc))
 (deps
  %{workspace_root}/config/sandbox-images.toml
  (source_tree %{workspace_root}/sandbox-images))
 (action (run %{test}))
 (libraries alcotest masc masc.fs_compat masc.masc_process unix))
