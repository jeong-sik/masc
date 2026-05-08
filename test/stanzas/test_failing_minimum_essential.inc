; Per-file dune stanza for the [Keeper_tool_policy.failing_minimum_tool_names]
; essential-MASC inclusion regression suite. Resolves board P1
; (9 keepers x 0 claimable masc_web_search). Lives here per
; test/stanzas/README.md to avoid the conflict-cascade hotspot
; in the legacy grouped (tests ...) stanza.

(test
 (name test_failing_minimum_essential)
 (modules test_failing_minimum_essential)
 (libraries masc_test_deps alcotest))
