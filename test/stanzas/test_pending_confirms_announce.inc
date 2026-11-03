(test
 (name test_pending_confirms_announce)
 (modules test_pending_confirms_announce)
 (libraries alcotest eio eio_main unix masc masc.operator masc.masc_types masc.masc_core
  masc.fs_compat masc_server masc_test_deps masc_workspace yojson))
