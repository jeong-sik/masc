; RFC tui-one-screen-grammar §10: the geometry harness sweeps terminal sizes
; through the pure layout decisions and checks their invariants.
(test
 (name test_tui_layout_geometry)
 (modules test_tui_layout_geometry)
 (libraries
  alcotest
  masc_tui_card
  masc_tui_frame
  masc_tui_message_layout
  masc_tui_overview_cards
  masc_tui_render_schedule
  masc_tui_value))
