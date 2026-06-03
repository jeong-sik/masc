; RFC-0203 Phase 3 — in-process gateway support added to
; Channel_gate_discord_state. Minimal-deps stanza to stay
; insulated from currently-broken masc linkage on main
; (ref MEMORY.md "CI gate skip two-strikes 24h" + ongoing
;  Json_util consolidation drift).
(test
 (name test_channel_gate_discord_state_in_process)
 (modules test_channel_gate_discord_state_in_process)
 (libraries alcotest unix masc.gate))
