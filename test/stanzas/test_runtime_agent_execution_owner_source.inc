; Agent Core execution runtime is created once by the server composition root,
; installed under its root switch, and never reconstructed by turn retry code.

(test
 (name test_runtime_agent_execution_owner_source)
 (modules test_runtime_agent_execution_owner_source)
 (deps
  ../lib/runtime/runtime_agent_execution_owner.ml
  ../lib/runtime/runtime_agent_execution_owner.mli
  ../lib/keeper_runtime/keeper_agent_core_execution_identity.mli
  ../lib/keeper/keeper_agent_core_execution_store.ml
  ../lib/server/server_runtime_bootstrap.ml
  ../lib/keeper/keeper_agent_run.ml
  ../lib/keeper/keeper_turn_driver.ml
  ../lib/keeper/keeper_turn_driver_try_provider.ml
  ../lib/runtime/runtime_agent.ml))
