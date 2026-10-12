(test
 (name test_keeper_event_genealogy_replay)
 (modules test_keeper_event_genealogy_replay)
 (deps fixtures/event_genealogy_replay/actual.json)
 (libraries masc_test_deps exact_output_fixture masc masc.runtime masc.masc_eio_context agent_core eio_main))
