(test
 (name test_keeper_event_genealogy_capture)
 (modules test_keeper_event_genealogy_capture)
 (deps fixtures/event_genealogy_selection/scenario.json)
 (libraries masc_test_deps exact_output_fixture masc masc.runtime masc.masc_eio_context agent_core eio_main))
