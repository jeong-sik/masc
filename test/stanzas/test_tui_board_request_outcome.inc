(test
 (name test_tui_board_request_outcome)
 (modules test_tui_board_request_outcome)
 (libraries
  masc_test_deps masc_server masc_tui_board_requests masc_tui_board_publication
  masc_tui_loader masc_tui_types masc_tui_workspace_result masc_tui_board_updates
  masc_tui_board_detail
  masc_tui_async_protocol masc_tui_credential masc_eio_context masc.http_client
  masc.masc_tool_blob_store eio eio_main httpun gluten unix yojson))
