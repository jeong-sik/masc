; Per-file dune stanza for the typed agent_runtime_status carrier suite
; (RFC-0089). Lives here per test/stanzas/README.md to avoid the
; conflict-runtime hotspot in the legacy grouped (tests ...) stanza.

(test
 (name test_keeper_agent_runtime_status)
 (modules test_keeper_agent_runtime_status)
 (libraries masc_test_deps masc masc_types alcotest))
