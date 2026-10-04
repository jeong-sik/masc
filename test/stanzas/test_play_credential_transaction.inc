(test
 (name test_play_credential_transaction)
 (modules test_play_credential_transaction)
 (libraries masc.machine_configuration masc_test_deps alcotest yojson unix eio eio_main masc.masc_process
  masc.dos_lane masc.server))
