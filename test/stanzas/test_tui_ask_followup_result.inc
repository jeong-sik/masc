(test
 (name test_tui_ask_followup_result)
 (modules test_tui_ask_followup_result)
 (libraries alcotest masc masc.masc_types masc.masc_workspace masc.server
  masc.keeper_runtime masc.fs_compat masc_test_deps masc_eio_context
  masc_tui_types masc_tui_async_protocol masc_tui_workspace_result
  masc_tui_workspace_job masc_tui_ask_projection masc_tui_message_input masc_tui_original_task_read masc_tui_fetched masc_tui_observation_origin masc_tui_ask_followup_observation masc.masc_log
  eio eio_main yojson unix mtime.clock.os mirage-crypto-rng.unix))
