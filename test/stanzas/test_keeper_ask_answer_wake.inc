(test
 (name test_keeper_ask_answer_wake)
 (modules test_keeper_ask_answer_wake)
 (libraries alcotest ast_grep masc masc.keeper_runtime masc_test_deps yojson unix)
 (deps
  (source_tree ../lib)))
