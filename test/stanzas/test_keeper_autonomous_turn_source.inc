; Dashboard reader for typed keeper turn records and their exact raw-trace
; run references. Direct turns are already in the chat store; public
; autonomous rows expose only the final text, never reasoning/tool payloads.
; Corrupt current records and missing trace files must be visible in logs and
; degrade to a skip rather than fail the dashboard request.

(test
 (name test_keeper_autonomous_turn_source)
 (modules test_keeper_autonomous_turn_source)
 (libraries masc_test_deps))
