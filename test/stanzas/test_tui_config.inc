(test
 (name test_tui_config)
 (modules test_tui_config)
 (libraries alcotest masc_tui_config masc_tui_chat_visit masc_tui_types
  masc.masc_core masc.runtime masc.keeper_registry masc.keeper_toml
  masc.toml_line_editor masc.runtime_toml_namespace eio eio_main unix))
