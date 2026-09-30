(test
 (name test_auth_credential_index_authority)
 (modules test_auth_credential_index_authority)
 (libraries masc_server httpun masc_test_deps alcotest unix eio eio_main masc.auth masc.masc_process masc.fs_compat masc.masc_types mirage-crypto-rng.unix yojson))
