; Its own stanza rather than ten lines appended to test/dune, where every
; suite added that way lands on the same line and two such pull requests
; conflict whatever else they touch (#36385).
(test
 (name test_tui_row_with_field)
 (modules test_tui_row_with_field)
 (libraries alcotest masc_tui_ansi masc_tui_message_layout masc_tui_theme))
