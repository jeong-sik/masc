(test
 (name test_keeper_continuity_request_view)
 (modules test_keeper_continuity_request_view)
 (deps
  %{workspace_root}/lib/keeper/keeper_turn_driver.ml
  %{workspace_root}/lib/keeper/keeper_turn_driver_try_provider.ml)
 (libraries masc_test_deps ast_grep))
