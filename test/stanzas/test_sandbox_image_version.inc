; Tag and recipe loading for versioned sandbox images; no docker, no daemon.
; The recipes and the files the ocaml recipe COPYs are deps, so the suite can
; check each COPY source is a listed input, and a pull request that edits any
; of them selects it.

(test
 (name test_sandbox_image_version)
 (modules test_sandbox_image_version)
 (deps
  (source_tree %{workspace_root}/sandbox-images)
  %{workspace_root}/masc.opam
  %{workspace_root}/masc.opam.locked
  %{workspace_root}/scripts/opam-pin-from-lock.sh)
 (action (run %{test}))
 (libraries alcotest unix masc.keeper_sandbox_image))
