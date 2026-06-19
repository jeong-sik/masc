; Regression for [Keeper_memory_bank.consolidate_memory_notes]: the cross-trace
; recurrence promotion must persist a trace_id, else [parse_memory_bank_row]
; silently purges the promoted long_term row on the next read. Per-file stanza
; per test/stanzas/README.md to avoid the legacy grouped-stanza conflict hotspot.

(test
 (name test_keeper_memory_bank_consolidation_provenance)
 (modules test_keeper_memory_bank_consolidation_provenance)
 (libraries masc_test_deps masc alcotest yojson))
