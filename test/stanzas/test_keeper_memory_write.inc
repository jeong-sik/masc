; Per-file dune stanza for the [Keeper_exec_memory.keeper_memory_write_json]
; validation suite (RFC-0035 P4). Lives here per
; test/stanzas/README.md to avoid the conflict-cascade hotspot
; in the legacy grouped (tests ...) stanza.

(test
 (name test_keeper_memory_write)
 (modules test_keeper_memory_write)
 (libraries masc_test_deps masc_mcp alcotest))
