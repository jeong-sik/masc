(test
 (name test_keeper_memory_select)
 (modules test_keeper_memory_select)
 (deps fixtures/memory_resolved_selection_replay/actual.json)
 (libraries masc_test_deps exact_output_fixture masc masc.runtime masc.masc_eio_context agent_core eio_main))
