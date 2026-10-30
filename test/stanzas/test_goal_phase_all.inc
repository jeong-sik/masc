; Per-file dune stanza for Goal_phase.all / all_actions completeness (RFC-0089).
; Lives here per test/stanzas/README.md to avoid the conflict-runtime hotspot
; in the legacy grouped (tests ...) stanza.

(test
 (name test_goal_phase_all)
 (modules test_goal_phase_all)
 (libraries masc_goal alcotest))
