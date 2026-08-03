(test
 (name test_server_oauth_protocol)
 (modules test_server_oauth_protocol)
 (libraries alcotest eio eio_main fs_compat httpun masc.auth masc.masc_core masc.server masc_types mirage-crypto-rng.unix unix yojson))
