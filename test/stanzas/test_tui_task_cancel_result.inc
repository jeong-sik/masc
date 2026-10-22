(test
 (name test_tui_task_cancel_result)
 (modules test_tui_task_cancel_result)
 (libraries alcotest masc masc.server masc.masc_workspace masc_test_deps masc.fs_compat
  masc_tui_original_task_read masc_tui_fetched masc_eio_context masc_tui_mcp masc_tui_types masc_tui_async_protocol masc_tui_workspace_result masc_tui_task_dispatch masc_tui_message_input masc_tui_command masc_tui_palette
  eio eio_main unix yojson mirage-crypto-rng.unix))
