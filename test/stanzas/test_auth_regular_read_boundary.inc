(test
 (name test_auth_regular_read_boundary)
 (modules test_auth_regular_read_boundary)
 (libraries masc_server httpun masc_test_deps alcotest unix eio eio_main masc.auth masc.fs_compat masc.masc_types mirage-crypto-rng.unix))
