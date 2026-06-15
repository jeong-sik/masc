; Per-file dune stanza for the [Keeper_memory_bank.memory_row_source] typed
; provenance carrier (RFC-0020). Lives here per test/stanzas/README.md to avoid
; the conflict-runtime hotspot in the legacy grouped (tests ...) stanza.

(test
 (name test_keeper_memory_row_source)
 (modules test_keeper_memory_row_source)
 (libraries masc_test_deps masc alcotest))
