; The fleet scan's section of the full health snapshot read as a fleet reading
; (RFC-0477): every key lands in its own field, and a section that cannot be
; what it claims is refused.

(test
 (name test_fleet_stream_health_section)
 (modules test_fleet_stream_health_section)
 (libraries masc alcotest yojson))
