(test
 (name test_keeper_oauth_identity)
 (modules test_keeper_oauth_identity)
 (libraries alcotest str uri yojson masc.keeper_identity masc.auth
   masc.embedded_config))
