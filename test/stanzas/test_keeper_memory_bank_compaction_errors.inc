; P0-6: memory-bank compaction typed-error surfacing (schema mismatch / write failure).

(test
 (name test_keeper_memory_bank_compaction_errors)
 (modules test_keeper_memory_bank_compaction_errors)
 (libraries masc_test_deps masc alcotest yojson))
