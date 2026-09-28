; Its own stanza rather than lines appended to test/dune, where every suite
; added that way lands on the same line and two such pull requests conflict
; whatever else they touch (#36385).
(test
 (name test_tui_detail_heading)
 (modules test_tui_detail_heading)
 (libraries
  alcotest
  masc_tui_ansi
  masc_tui_message_layout
  masc_tui_render_prim
  masc_tui_theme
  masc_tui_types))
