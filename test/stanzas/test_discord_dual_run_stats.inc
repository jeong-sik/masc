; RFC-0203 Phase 2 — Discord_dual_run_stats unit tests.
; Same minimal-deps approach as test_discord_rest_client / Phase 1
; stanza: link only through masc_mcp.gate to stay insulated from
; the parent masc_mcp library (MEMORY.md "CI gate skip two-strikes
; 24h" 2026-05-28 #19340 cascade cycle reference).
(test
 (name test_discord_dual_run_stats)
 (modules test_discord_dual_run_stats)
 (libraries alcotest unix yojson masc_mcp.gate))
