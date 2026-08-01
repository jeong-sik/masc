(test
 (name test_auth_oauth)
 (modules test_auth_oauth)
 (libraries alcotest eio eio_main fs_compat masc.auth masc.masc_core masc_types mirage-crypto-rng.unix unix))
