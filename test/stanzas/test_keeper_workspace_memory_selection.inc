(test
 (name test_keeper_workspace_memory_selection)
 (modules test_keeper_workspace_memory_selection)
 (deps
  ../config/prompts/keeper.memory.selection.md
  ../config/prompts/keeper.memory.selection.criteria.md
  ../config/prompts/keeper.memory.selection.candidate.md)
 (libraries masc_test_deps masc alcotest))
