; Per-file dune stanza for the keeper Memory write runtime
; validation suite. Lives here per
; test/stanzas/README.md to avoid the conflict-runtime hotspot
; in the legacy grouped (tests ...) stanza.

(test
 (name test_keeper_memory_write)
 (modules test_keeper_memory_write)
 (libraries masc_test_deps masc alcotest))
