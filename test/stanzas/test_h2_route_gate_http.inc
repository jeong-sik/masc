; The HTTP/2 gateway runs the gate that goes with the kind the HTTP/1 router records.

(test
 (name test_h2_route_gate_http)
 (modules test_h2_route_gate_http)
 (libraries masc_test_deps h2 h2-eio bigstringaf))
