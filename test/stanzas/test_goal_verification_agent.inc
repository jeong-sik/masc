; Per-file dune stanza for the RFC-0387 stage-2 PR-2 surface: the goal
; verifier caller (lib/goal_verification_agent.ml) that drains the ledger's
; durable pending requests through the verifier_exact lane and commits
; verdicts via the application-owned typed commit boundary.

(test
 (name test_goal_verification_agent)
 (modules test_goal_verification_agent)
 (libraries masc_test_deps))
