(test
 (name test_tui_render_memory_librarian_pending)
 (modules test_tui_render_memory_librarian_pending)
 (libraries
  memory_keeper_health_fixture masc_tui_memory_usage masc_tui_surface_search masc_tui_value
  masc_tui_pick_list masc_tui_memory_writer
  alcotest
  masc
  masc_tui_acting_pane
  masc_tui_ansi
  masc_tui_fetched
  masc_tui_frame
  masc_tui_hit
  masc_tui_press
  masc_tui_roster_pane
  masc_tui_scroll
  masc_tui_message_layout
  masc_tui_memory_tree
  masc_tui_memory_world
  masc_tui_render_memory
  masc_tui_theme
  masc_tui_types  unix
))
