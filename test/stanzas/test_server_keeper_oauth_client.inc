(test
 (name test_server_keeper_oauth_client)
 (modules test_server_keeper_oauth_client)
 (libraries alcotest str unix yojson masc.server masc.keeper_identity
   masc.embedded_config))
