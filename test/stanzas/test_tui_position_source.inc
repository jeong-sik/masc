(test
 (name test_tui_position_source)
 (modules test_tui_position_source)
 (deps (glob_files %{workspace_root}/bin/*.ml))
 (libraries alcotest))
