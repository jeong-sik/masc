(test
 (name test_keeper_memory_resolved_selection_capture)
 (modules test_keeper_memory_resolved_selection_capture)
 (deps fixtures/memory_successor_http_replay/event-branches.json)
 (libraries masc_test_deps masc masc.runtime masc.masc_eio_context agent_core eio_main))
