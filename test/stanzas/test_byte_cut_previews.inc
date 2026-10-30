; No OCaml source cuts a string at a byte offset and appends an ellipsis
; (issue #44179). The scan reads the source files of lib, bin and packages;
; source_tree leaves out the .ml files that rules generate.
(rule
 (alias runtest-test_byte_cut_previews)
 (deps
  test_byte_cut_previews.py
  (source_tree %{workspace_root}/lib)
  (source_tree %{workspace_root}/bin)
  (source_tree %{workspace_root}/packages))
 (action
  (run python3 %{dep:test_byte_cut_previews.py}
   %{workspace_root}/lib %{workspace_root}/bin %{workspace_root}/packages)))

(alias
 (name runtest)
 (deps (alias runtest-test_byte_cut_previews)))
