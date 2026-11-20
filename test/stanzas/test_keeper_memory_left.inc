; Per-file dune stanza for the facts that left a Keeper's Memory, as
; keeper_memory_search reads them from the commit log.
; Lives here per test/stanzas/README.md.

(test
 (name test_keeper_memory_left)
 (modules test_keeper_memory_left)
 (libraries masc alcotest yojson unix))
