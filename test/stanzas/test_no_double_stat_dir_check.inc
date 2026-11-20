; Ensure lib/ and bin/ never re-introduce two-stat file_exists && is_directory (#53942).
(rule
 (alias runtest-test_no_double_stat_dir_check)
 (deps
  test_no_double_stat_dir_check.py
  (glob_files_rec %{workspace_root}/lib/*.ml)
  (glob_files_rec %{workspace_root}/lib/*.mli)
  (glob_files_rec %{workspace_root}/bin/*.ml)
  (glob_files_rec %{workspace_root}/bin/*.mli))
 (action
  (run python3 %{dep:test_no_double_stat_dir_check.py})))

(alias
 (name runtest)
 (deps (alias runtest-test_no_double_stat_dir_check)))
