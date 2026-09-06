(test
 (name test_tui_row_wiring)
 (modules test_tui_row_wiring)
 ; Read through Ast_grep, so the source is a dep: without it the test runs
 ; against whatever the build directory happens to hold.
 (deps
  %{workspace_root}/bin/masc_tui_render.ml
  %{workspace_root}/bin/masc_tui_render_memory.ml
  %{workspace_root}/bin/masc_tui_loader.ml)
 (libraries alcotest ast_grep))
