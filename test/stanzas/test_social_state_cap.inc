; Gen8 persistence-layer guard: cap_social_state bounds the BDI
; speech v1 narrative fields (belief_summary, active_desire,
; current_intention, blocker, need) carried across turns via
; previous_state. Stays silent does not clear state, so without
; this cap the narrative accumulates monotonically.

(test
 (name test_social_state_cap)
 (modules test_social_state_cap)
 (libraries masc_test_deps))
