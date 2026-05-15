open Alcotest

(** RFC-0085 PR-13 — Underscore-prefix bindings audited file-by-file.

    1 truly dead: governance_pipeline_risk._tool_names_of_input
       (definition only, 0 callers) -> deleted.

    8 active (PR-12 pattern: misleading _ prefix on used bindings):
       - config_dir_resolver._cached_resolution
       - tool_code_write._policy_config_cache
       - tool_keeper._keeper_list_cache
       - tool_board._board_list_cache
       - context_compact_oas._legacy_memory_summary_prefix
       - context_compact_oas._legacy_goal_prefix
       - governance_pipeline_risk._destructive_pattern_strings
       - tool_coord._status_cache
    All renamed (drop _ prefix), callers in same file updated.

    Original test scanned [count_string_literals], which examines only
    [Pconst_string] nodes — identifiers are NOT string literals, so the
    test would pass even if [_xxx] identifiers were reintroduced.
    This revision uses [count_value_bindings ~name], which inspects
    [Ppat_var] nodes (actual identifier bindings). *)

let dead_identifiers =
  [ "lib/governance_pipeline_risk.ml", "_tool_names_of_input" ]
;;

let renamed_identifiers =
  [ "lib/config_dir_resolver.ml", "_cached_resolution", "cached_resolution"
  ; "lib/tool_code_write.ml", "_policy_config_cache", "policy_config_cache"
  ; "lib/tool_keeper.ml", "_keeper_list_cache", "keeper_list_cache"
  ; "lib/tool_board.ml", "_board_list_cache", "board_list_cache"
  ; ( "lib/context_compact_oas.ml"
    , "_legacy_memory_summary_prefix"
    , "legacy_memory_summary_prefix" )
  ; "lib/context_compact_oas.ml", "_legacy_goal_prefix", "legacy_goal_prefix"
  ; ( "lib/governance_pipeline_risk.ml"
    , "_destructive_pattern_strings"
    , "destructive_pattern_strings" )
  ; "lib/tool_coord.ml", "_status_cache", "status_cache"
  ]
;;

let test_dead_identifiers_gone () =
  List.iter
    (fun (path, name) ->
      let n = Ast_grep.count_value_bindings ~module_path:path ~name in
      let msg = Printf.sprintf "%s should be deleted in %s" name path in
      check int msg 0 n)
    dead_identifiers
;;

let test_renamed_old_names_gone () =
  List.iter
    (fun (path, old_name, _new_name) ->
      let n = Ast_grep.count_value_bindings ~module_path:path ~name:old_name in
      let msg =
        Printf.sprintf "old name %s should be removed in %s" old_name path
      in
      check int msg 0 n)
    renamed_identifiers
;;

let test_renamed_new_names_present () =
  List.iter
    (fun (path, _old_name, new_name) ->
      let n = Ast_grep.count_value_bindings ~module_path:path ~name:new_name in
      let msg =
        Printf.sprintf "new name %s should be defined in %s" new_name path
      in
      if n < 1 then failf "%s — count=%d" msg n)
    renamed_identifiers
;;

let () =
  run
    "rfc-0085-pr-13-underscore-rename"
    [ ( "dead removal"
      , [ test_case "dead _tool_names_of_input gone" `Quick test_dead_identifiers_gone
        ] )
    ; ( "active rename"
      , [ test_case "old underscore names gone" `Quick test_renamed_old_names_gone
        ; test_case "new names present" `Quick test_renamed_new_names_present
        ] )
    ]
;;
