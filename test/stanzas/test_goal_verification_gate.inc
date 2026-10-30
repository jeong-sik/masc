; Per-file dune stanza for the RFC-0387 surface: the B1 creation
; requirement, the verification ledger (+ its observability join), and the
; stage-2 completion gate (Verifying phase, proof/criterion verdict actions,
; re-arm). Lives here per test/stanzas/README.md to avoid the
; conflict-runtime hotspot in the legacy grouped (tests ...) stanza.

(test
 (name test_goal_verification_gate)
 (modules test_goal_verification_gate)
 (libraries masc_test_deps))
