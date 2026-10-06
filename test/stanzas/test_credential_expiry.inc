(test
 (name test_credential_expiry)
 (modules test_credential_expiry)
 (libraries masc.machine_configuration masc_test_deps alcotest masc.auth masc.masc_types masc masc.dos_lane eio eio_main
  eio.mock fs_compat time_compat mirage-crypto-rng.unix))
