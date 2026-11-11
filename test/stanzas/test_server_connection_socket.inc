(test
 (name test_server_connection_socket)
 (modules test_server_connection_socket)
 (libraries masc masc.server alcotest eio eio.mock eio.unix eio_main h2 httpun gluten cstruct fmt unix))
