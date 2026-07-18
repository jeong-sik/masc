; World-state prompt provenance stamp + supersession (#25193): typed
; metadata detection (role-gated, content never inspected) and the masc
; message-json metadata round-trip fix.

(test
 (name test_keeper_world_state_supersede)
 (modules test_keeper_world_state_supersede)
 (libraries masc_test_deps))
