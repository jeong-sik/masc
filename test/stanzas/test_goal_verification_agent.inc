; Per-file dune stanza for the goal verifier caller
; (lib/goal_verification_agent.ml) that drains the ledger's durable pending
; requests through the verifier_exact lane and commits verdicts via the
; application-owned typed commit boundary.

(test
 (name test_goal_verification_agent)
 (modules test_goal_verification_agent)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries goal_measure_fixture masc.goal_measure
  eio.mock
  masc_test_deps
  masc.agent_core.digest
  masc_candle
  masc_candle_store
  masc_candle_config
  masc_candle_runtime))
