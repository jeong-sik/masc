; Which gate the HTTP/2 gateway runs for each kind of route.

(test
 (name test_server_h2_route_gate)
 (modules test_server_h2_route_gate)
 (action (run %{test}))
 (libraries masc_test_deps masc.server alcotest httpun))
