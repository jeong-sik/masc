(test
 (name test_tui_keys)
 (modules test_tui_keys)
 (libraries alcotest yojson masc masc.masc_goal masc.repo_manager
  masc_tui_mcp masc_tui_types
  masc_tui_keys masc_tui_keeper_mark masc_tui_memory_mark masc_tui_footer
  masc_tui_config_mark
  masc_tui_file_icon
  masc_tui_message_layout
   masc_tui_fetched masc_tui_keeper_chat_transcript))
