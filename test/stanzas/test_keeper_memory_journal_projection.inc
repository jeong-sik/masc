; The librarian journal as the dashboard sees it. A failed pass and a commit
; must project to different shapes, and a torn line must keep its place.

(test
 (name test_keeper_memory_journal_projection)
 (modules test_keeper_memory_journal_projection)
 (libraries alcotest masc masc_test_deps unix yojson))
