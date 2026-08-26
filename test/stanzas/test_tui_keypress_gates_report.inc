(test
 (name test_tui_keypress_gates_report)
 (modules test_tui_keypress_gates_report)
 ; Read through Ast_grep, so the source is a dep: without it the test reads
 ; whatever the build directory happens to hold.
 (deps %{workspace_root}/bin/masc_tui.ml)
 (libraries alcotest ast_grep))
