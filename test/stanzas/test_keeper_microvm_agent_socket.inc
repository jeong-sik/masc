; The guest agent's boot: where its socket is on both sides, the plan that
; starts it, and the host path made ready just before that boot.
(test
 (name test_keeper_microvm_agent_socket)
 (modules test_keeper_microvm_agent_socket)
 (libraries masc_test_deps exec_ssh_protocol))
