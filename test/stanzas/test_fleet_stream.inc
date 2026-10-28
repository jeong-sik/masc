; The wire shape of the keeper fleet events (RFC-0477): every event survives
; the wire, and every refusal names the field that caused it.

(test
 (name test_fleet_stream)
 (modules test_fleet_stream)
 (libraries masc alcotest yojson))
