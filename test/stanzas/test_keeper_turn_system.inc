; RFC-0491 §3.2: the System a keeper turn sends keeps the articles it was
; rendered with while the carried range keeps its front.

(test
 (name test_keeper_turn_system)
 (modules test_keeper_turn_system)
 (deps
  (source_tree %{workspace_root}/config/prompts))
 (libraries alcotest masc masc_test_deps))
