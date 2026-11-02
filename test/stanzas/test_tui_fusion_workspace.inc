(test
 (name test_tui_fusion_workspace)
 (modules test_tui_fusion_workspace)
 (libraries masc_test_deps masc_tui_loader masc_tui_credential masc_tui_workspace_read masc_tui_kept_reads
  masc_tui_observer masc_tui_fusion_updates masc_tui_types masc_tui_fetched
  masc_server masc_eio_context masc.http_client eio eio_main httpun httpun-eio gluten unix yojson))
