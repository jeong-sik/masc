(test
 (name test_auth_file_backed_transaction)
 (modules test_auth_file_backed_transaction)
 (libraries masc_server httpun masc_test_deps alcotest unix eio eio_main masc.auth masc.masc_process masc.fs_compat masc.masc_types masc.string_util masc.time_compat mirage-crypto-rng.unix yojson))
