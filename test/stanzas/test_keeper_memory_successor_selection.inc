(test
 (name test_keeper_memory_successor_selection)
 (modules test_keeper_memory_successor_selection)
 (deps
  ../config/prompts/keeper.memory.successor_selection.md
  ../config/prompts/keeper.memory.successor_selection.criteria.md)
 (libraries masc_test_deps masc masc.runtime masc.masc_eio_context alcotest eio_main eio.mock))
