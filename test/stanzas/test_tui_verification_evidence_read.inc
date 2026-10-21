(test
 (name test_tui_verification_evidence_read)
 (modules test_tui_verification_evidence_read)
 (libraries alcotest masc masc.server masc.masc_workspace masc.http_client
  masc.fs_compat masc_tui_workspace_read masc_tui_types masc_tui_fetched
  masc_tui_evidence_picture masc_tui_portrait_view
  eio eio_main httpun unix yojson base64 digestif))
