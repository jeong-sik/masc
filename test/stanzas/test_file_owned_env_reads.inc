; Reject literal-shaped getenv calls for file-owned names. Binding candidates
; are advisory because the scanner does not resolve lexical/module scope.
; The dump writes the names the settings registry marks file-owned;
; the scan reads the source files of lib and bin. source_tree leaves out the .ml
; files that rules generate.
(executable
 (name dump_file_owned_env_names)
 (modules dump_file_owned_env_names)
 (libraries masc.config))

(rule
 (targets file_owned_env_names.txt)
 (action
  (with-stdout-to
   %{targets}
   (run %{exe:dump_file_owned_env_names.exe}))))

(rule
 (alias runtest-test_file_owned_env_reads)
 (deps
  test_file_owned_env_reads.py
  test_byte_cut_previews.py
  file_owned_env_names.txt
  (source_tree %{workspace_root}/lib)
  (source_tree %{workspace_root}/bin))
 (action
  (run python3 %{dep:test_file_owned_env_reads.py}
   %{dep:file_owned_env_names.txt}
   %{workspace_root}/lib %{workspace_root}/bin)))

(alias
 (name runtest)
 (deps (alias runtest-test_file_owned_env_reads)))
