; Typed route registration: the kind each route records and the wrapper it gets.

(test
 (name test_server_route)
 (modules test_server_route)
 (action (run %{test}))
 (libraries masc_test_deps masc.server alcotest yojson bigstringaf httpun eio eio_main))
