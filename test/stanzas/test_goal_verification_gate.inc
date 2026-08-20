; Per-file dune stanza for the RFC-0387 stage-1 surface: the B1 creation
; requirement and the record-only verification ledger (+ its observability
; join). Lives here per test/stanzas/README.md to avoid the conflict-runtime
; hotspot in the legacy grouped (tests ...) stanza.

(test
 (name test_goal_verification_gate)
 (modules test_goal_verification_gate)
 (libraries masc_test_deps))
