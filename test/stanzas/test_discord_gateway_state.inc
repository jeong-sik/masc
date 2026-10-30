; RFC-0203 Phase 1.6 — pure state-machine tests.
; Direct minimal deps instead of masc_test_deps superset so we don't
; transitively pull modules currently broken on main (runtime/keeper
; type drift, ref MEMORY.md CI gate skip two-strikes 24h note).
(test
 (name test_discord_gateway_state)
 (modules test_discord_gateway_state)
 (libraries alcotest yojson masc.gate))
