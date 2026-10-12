(test
 (name test_keeper_memory_resolved_selection_replay)
 (modules test_keeper_memory_resolved_selection_replay)
 (deps fixtures/memory_resolved_selection_replay/actual.json fixtures/event_genealogy_selection/scenario.json)
 (libraries masc_test_deps exact_output_fixture masc masc.runtime masc.masc_eio_context agent_core eio_main))
