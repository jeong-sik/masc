; Per-file dune stanza for goal verification: the success condition a new
; goal must declare, the verification ledger (+ its observability join), and
; the completion gate (Verifying phase, proof/criterion verdict actions,
; re-arm). Lives here per test/stanzas/README.md to avoid the
; conflict-runtime hotspot in the legacy grouped (tests ...) stanza.

(test
 (name test_goal_verification_gate)
 (modules test_goal_verification_gate)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries goal_measure_fixture masc.goal_measure masc_test_deps))
