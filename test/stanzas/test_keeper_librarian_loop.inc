; The server-owned Librarian loop: one per keeper, runs at start and when
; woken, parks otherwise, and is retired only by a purge.

(test
 (name test_keeper_librarian_loop)
 (modules test_keeper_librarian_loop)
 (libraries masc_test_deps))
