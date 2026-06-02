; Per-file dune stanza for the [Keeper_tool_policy.is_masc_write_allowed]
; path-handling regression suite.  Lives here per
; test/stanzas/README.md to avoid the conflict-runtime hotspot
; in the legacy grouped (tests ...) stanza.

(test
 (name test_keeper_tool_policy_paths)
 (modules test_keeper_tool_policy_paths)
 (libraries masc_test_deps))
