(test
 (name test_play_current_credential_authority)
 (modules test_play_current_credential_authority)
 (action (run %{test}))
 (libraries masc_test_deps alcotest yojson bigstringaf unix eio eio_main eio.mock
  masc.masc_core masc.dos_lane masc.server masc.auth masc.fs_compat time_compat
  mirage-crypto-rng.unix))
