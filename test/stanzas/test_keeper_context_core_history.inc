; The history files under a trace: every line names the turn that wrote it,
; a tool call an official-client turn made leaves an observation line, and
; appends are locked and durable.

(test
 (name test_keeper_context_core_history)
 (modules test_keeper_context_core_history)
 (libraries masc_test_deps))
