(test
 (name test_tui_workspace_precondition)
 (modules test_tui_workspace_precondition)
 (libraries alcotest masc masc_server masc_tui_loader masc_tui_workspace_precondition
  masc_test_deps masc_eio_context masc.http_client eio eio_main httpun gluten
  uri yojson))
