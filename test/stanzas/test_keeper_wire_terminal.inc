; Wire-terminal synthesis for keeper chat operations (#28811): registry
; transitions plus the settle-hook decision table that closes cancelled
; turn streams with RUN_ERROR.

(test
 (name test_keeper_wire_terminal)
 (modules test_keeper_wire_terminal)
 (libraries masc_test_deps))
