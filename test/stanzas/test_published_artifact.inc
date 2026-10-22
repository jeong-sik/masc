(test
 (name test_published_artifact)
 (modules test_published_artifact)
 (libraries masc masc_test_deps masc.server masc.masc_core masc.masc_tool_blob_store
  masc.fs_compat masc.board_handlers masc.tool_types masc.masc_types
  alcotest eio_main unix yojson httpun))

(test
 (name test_published_artifact_checks)
 (modules test_published_artifact_checks)
 (libraries masc masc.server masc.masc_core masc.masc_tool_blob_store masc.fs_compat
  alcotest eio eio_main eio.unix unix yojson))
