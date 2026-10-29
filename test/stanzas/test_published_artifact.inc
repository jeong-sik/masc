(test
 (name test_artifact_project_build)
 (modules test_artifact_project_build)
 (libraries masc masc.masc_core masc.masc_tool_blob_store
  alcotest base64 masc.agent_core.digest eio_main unix yojson))

(test
 (name test_artifact_project_source)
 (modules test_artifact_project_source)
 (libraries masc masc.masc_core masc.masc_tool_blob_store
  alcotest base64 masc.agent_core.digest eio_main unix yojson))

(test
 (name test_published_artifact)
 (modules test_published_artifact)
 (libraries masc masc_test_deps masc.server masc.masc_core masc.masc_tool_blob_store
  masc.fs_compat masc.board_handlers masc.tool_types masc.masc_types
  alcotest eio eio_main eio.unix unix yojson httpun))

(test
 (name test_published_artifact_share)
 (modules test_published_artifact_share)
 (libraries masc alcotest yojson))

(test
 (name test_published_artifact_checks)
 (modules test_published_artifact_checks)
 (libraries masc masc.server masc.masc_core masc.masc_tool_blob_store masc.fs_compat
  alcotest eio eio_main eio.unix unix yojson))

(test
 (name test_artifact_app_data)
 (modules test_artifact_app_data)
 (libraries masc masc.server masc.masc_core masc.masc_random_id masc.fs_compat
  alcotest eio eio_main eio.unix unix yojson))

(test
 (name test_artifact_drafts)
 (modules test_artifact_drafts)
 (libraries masc masc.artifact_document_engine masc.masc_process masc.masc_core masc.masc_random_id masc.fs_compat
  alcotest eio eio_main unix yojson))

(test
 (name test_artifact_discussion)
 (modules test_artifact_discussion)
 (libraries masc masc.artifact_document_engine masc.masc_process masc.masc_core masc.masc_random_id masc.fs_compat
  alcotest eio eio_main unix yojson))

(test
 (name test_artifact_draft_live)
 (modules test_artifact_draft_live)
 (libraries masc masc.artifact_document_engine alcotest eio eio_main yojson))

(test
 (name test_keeper_artifact_draft)
 (modules test_keeper_artifact_draft)
 (libraries masc masc.tool_types masc.artifact_document_engine masc.masc_process masc.masc_core masc.masc_types masc.fs_compat
  alcotest eio eio_main unix yojson))

(test
 (name test_keeper_artifact_draft_bundle)
 (modules test_keeper_artifact_draft_bundle)
 (libraries masc masc_test_deps masc.masc_random_id masc.tool_types masc.artifact_document_engine masc.masc_process masc.masc_core masc.masc_types masc.fs_compat
  alcotest eio eio_main unix yojson))
