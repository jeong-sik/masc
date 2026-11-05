; A standing rule change is announced after the Gate snapshot is dropped.

(test
 (name test_gate_rules_announce)
 (modules test_gate_rules_announce)
 (libraries masc masc.server masc.keeper_approval masc_test_deps eio_main))
