(test
 (name test_server_keeper_oauth_disconnect)
 (modules test_server_keeper_oauth_disconnect)
 (libraries alcotest str unix yojson masc.server masc.keeper_identity
   masc.embedded_config masc masc.auth masc.masc_types eio eio_main httpun
   bigstringaf fs_compat))
