; A turn restored from an Anthropic-lane checkpoint keeps the context carrier
; the lane saved, so the next request is not refused.

(test
 (name test_keeper_turn_start_history_roles)
 (modules test_keeper_turn_start_history_roles)
 (deps
  (source_tree %{workspace_root}/config/prompts))
 (libraries alcotest masc masc_test_deps eio_main yojson))
