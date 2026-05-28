; RFC-0203 Phase 3 — Discord_tool_helpers unit tests.
; Same minimal-deps approach as test_discord_rest_client: link only
; through masc_mcp.gate to stay insulated from the pre-existing
; cascade_capacity_probe cycle in the parent masc_mcp library
; (MEMORY.md "CI gate skip two-strikes 24h", 2026-05-28 #19340).
(test
 (name test_tool_discord_dispatch)
 (modules test_tool_discord_dispatch)
 (libraries alcotest astring unix yojson masc_mcp.gate masc_mcp.tool_types))
