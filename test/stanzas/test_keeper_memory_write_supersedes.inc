; Per-file dune stanza for keeper_memory_write's supersedes argument.
; Lives here per test/stanzas/README.md.

(test
 (name test_keeper_memory_write_supersedes)
 (modules test_keeper_memory_write_supersedes)
 (libraries masc_test_deps masc alcotest))
