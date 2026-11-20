(test
 (name test_tui_chat_escape_and_interrupt_keys)
 (modules test_tui_chat_escape_and_interrupt_keys)
 (libraries alcotest eio eio_main mtime.clock.os masc_tui_types masc_tui_keeper_chat_projection
  masc_tui_keeper_chat_live masc_tui_esc_interrupt masc_tui_workspace_result masc_tui_transport
  masc_tui_chat_dispatch masc_tui_chat_input))
