; Runtime_agent must forward one caller-owned Agent Core execution store to
; every execution strategy selected by run_blocks.

(test
 (name test_runtime_agent_execution_store_source)
 (modules test_runtime_agent_execution_store_source)
 (deps
  ../lib/runtime/runtime_agent.ml
  ../lib/runtime/runtime_agent.mli))
