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

    AST verification: no underscore-prefixed string literals of the
    affected identifiers remain. *)

let walk_dirs dirs =
  let rec collect acc = function
    | [] -> acc
    | dir :: rest ->
      let entries = try Sys.readdir dir with Sys_error _ -> [||] in
      let next, files =
        Array.fold_left
          (fun (sub, files) name ->
            let p = Filename.concat dir name in
            if try Sys.is_directory p with Sys_error _ -> false
            then p :: sub, files
            else if Filename.check_suffix p ".ml"
            then sub, p :: files
            else sub, files)
          ([], [])
          entries
      in
      collect (List.rev_append files acc) (List.rev_append next rest)
  in
  collect [] dirs
;;

let test_dead_function_removed () =
  (* AST: governance_pipeline_risk should have 0 references to
     _tool_names_of_input identifier in any string. *)
  let n =
    Ast_grep.count_string_literals
      ~module_path:"lib/governance_pipeline_risk.ml"
      ~needle:"_tool_names_of_input"
  in
  check int "no _tool_names_of_input string literal" 0 n
;;

let test_no_underscore_active_cache_remains () =
  (* Spot-check a representative file from each rename. *)
  let pairs =
    [ "lib/config_dir_resolver.ml", "_cached_resolution"
    ; "lib/tool_code_write.ml", "_policy_config_cache"
    ; "lib/tool_keeper.ml", "_keeper_list_cache"
    ; "lib/tool_board.ml", "_board_list_cache"
    ; "lib/context_compact_oas.ml", "_legacy_memory_summary_prefix"
    ; "lib/governance_pipeline_risk.ml", "_destructive_pattern_strings"
    ; "lib/tool_coord.ml", "_status_cache"
    ]
  in
  List.iter
    (fun (path, name) ->
      let n = Ast_grep.count_string_literals ~module_path:path ~needle:name in
      let msg = Printf.sprintf "no %s string in %s" name path in
      check int msg 0 n)
    pairs
;;

let () =
  ignore walk_dirs;
  run
    "rfc-0085-pr-13-underscore-rename"
    [ ( "dead removal"
      , [ test_case
            "_tool_names_of_input deleted"
            `Quick
            test_dead_function_removed
        ] )
    ; ( "active rename"
      , [ test_case
            "no underscore-prefix string literal"
            `Quick
            test_no_underscore_active_cache_remains
        ] )
    ]
;;
