(test
 (name test_tui_board_read_title)
 (modules test_tui_board_read_title)
 (libraries alcotest ast_grep compiler-libs.common masc_tui_message_layout masc_tui_render_prim masc_tui_theme)
 ; Read through Ast_grep, so the source it reads is a dep.
 (deps %{workspace_root}/bin/masc_tui_render.ml))
