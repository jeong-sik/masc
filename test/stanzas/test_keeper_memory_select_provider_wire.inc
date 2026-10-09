(test
 (name test_keeper_memory_select_provider_wire)
 (modules test_keeper_memory_select_provider_wire)
 (deps fixtures/memory_select_tool_replay/actual.json)
 (libraries masc_test_deps exact_output_fixture masc masc.runtime masc.masc_eio_context agent_core eio_main))
