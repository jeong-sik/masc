(test
 (name test_tui_tab_strip)
 (modules test_tui_tab_strip)
 (libraries alcotest ast_grep compiler-libs.common masc_tui_ansi masc_tui_theme)
 ; Read through Ast_grep, so the source it reads is a dep.
 (deps %{workspace_root}/bin/masc_tui_render.ml))
