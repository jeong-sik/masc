; Runtime-agent cleanup must re-raise cancellation.

(test
 (name test_runtime_agent_close_cancel_source)
 (modules test_runtime_agent_close_cancel_source)
 (deps ../lib/runtime/runtime_agent.ml))
