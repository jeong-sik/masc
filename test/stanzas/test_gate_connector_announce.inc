(test
 (name test_gate_connector_announce)
 (modules test_gate_connector_announce)
 (libraries alcotest eio eio_main unix masc
  masc.fs_compat masc_gate masc_server masc_test_deps masc_workspace yojson))
