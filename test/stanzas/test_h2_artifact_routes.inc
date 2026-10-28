(test
 (name test_h2_artifact_routes)
 (modules test_h2_artifact_routes)
 (libraries masc masc_test_deps masc.server masc.auth masc.masc_core masc.masc_types masc.masc_eio_context
  masc.masc_process masc.fs_compat alcotest base64 bigstringaf eio eio.unix eio_main h2 h2-eio httpun unix uri yojson))
