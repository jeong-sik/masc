; RFC-0223 P2 — Gate_surface (typed connector surface + presence).
; Minimal-deps stanza, same insulation rationale as
; test_channel_gate_discord_state_in_process.
(test
 (name test_gate_surface)
 (modules test_gate_surface)
 (libraries alcotest unix yojson masc.gate))
