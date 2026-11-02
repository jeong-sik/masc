(test
 (name test_server_outbound_address)
 (modules test_server_outbound_address)
 (libraries alcotest eio eio_main fmt ipaddr masc.auth masc.http_client masc.server unix uri))
