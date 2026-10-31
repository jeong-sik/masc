(test
 (name test_keeper_memory_select_provider_wire)
 (modules test_keeper_memory_select_provider_wire)
 (deps fixtures/event_genealogy_replay/actual.json
  ../config/prompts/keeper.memory.selection.md
  ../config/prompts/keeper.memory.selection.criteria.md
  ../config/prompts/keeper.memory.selection.candidate.md
  ../config/prompts/keeper.memory.selection.request_context.md)
 (libraries masc_test_deps exact_output_fixture masc masc.runtime masc.masc_eio_context agent_core eio_main))
