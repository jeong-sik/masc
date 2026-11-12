(test
 (name test_tui_execute_stream_http)
 (modules test_tui_execute_stream_http play_observer_fixture)
 (libraries alcotest masc masc_server masc_tui_loader masc_tui_fleet_stream
  masc_tui_credential
  masc_test_deps masc_tui_workspace_read masc_eio_context masc.dashboard
  masc.http_client masc.string_util masc.sse_wire eio eio_main unix httpun gluten
  uri yojson))
