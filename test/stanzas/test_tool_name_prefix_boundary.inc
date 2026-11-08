(test
 (name test_tool_name_prefix_boundary)
 (modules test_tool_name_prefix_boundary)
 (deps (glob_files_rec %{workspace_root}/config/tools/*.toml))
 (libraries alcotest))
