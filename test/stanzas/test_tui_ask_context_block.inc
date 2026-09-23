(test
 (name test_tui_ask_context_block)
 (modules test_tui_ask_context_block)
 ; The drop notice lives in the executable's renderer, which no test can
 ; link, so that one assertion is read through Ast_grep. The source is a dep:
 ; without it the test reads a cached verdict and stays green while the line
 ; it asserts is gone.
 (deps %{workspace_root}/bin/masc_tui_render.ml)
 (libraries alcotest ast_grep masc masc_tui_render_prim))
