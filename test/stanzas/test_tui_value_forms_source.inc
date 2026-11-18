(test
 (name test_tui_value_forms_source)
 (modules test_tui_value_forms_source)
 (deps
  (glob_files %{project_root}/bin/masc_tui*.ml))
 (libraries alcotest))
