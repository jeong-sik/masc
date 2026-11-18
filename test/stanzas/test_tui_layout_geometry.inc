; RFC tui-one-screen-grammar §10: the geometry harness sweeps terminal sizes
; through the pure layout decisions and the surface frame finish_surface
; assembles, and checks their invariants.
(test
 (name test_tui_layout_geometry)
 (modules test_tui_layout_geometry)
 (libraries
  alcotest
  masc
  masc_tui_agenda
  masc_tui_ansi
  masc_tui_card
  masc_tui_frame
  masc_tui_frame_presenter
  masc_tui_message_layout
  masc_tui_overview_cards
  masc_tui_render_prim
  masc_tui_render_schedule
  masc_tui_too_small_hint
  masc_tui_types
  masc_tui_value))
