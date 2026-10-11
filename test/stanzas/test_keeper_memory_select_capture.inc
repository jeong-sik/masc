(test
 (name test_keeper_memory_select_capture)
 (modules test_keeper_memory_select_capture)
 (deps fixtures/memory_resolved_selection_replay/actual.json)
 (libraries masc_test_deps exact_output_fixture masc masc.runtime masc.masc_eio_context agent_core eio_main))
