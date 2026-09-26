(test
 (name test_tui_approvals_footer_matches_the_sheet)
 (modules test_tui_approvals_footer_matches_the_sheet)
 (libraries alcotest masc_tui_footer masc_tui_keys masc_tui_render_prim
  ; the ask fixture builds Tui_decode rows: the answering row draws its
  ; choice and editor keys only when the selected question has them
  masc
  masc_tui_types))
