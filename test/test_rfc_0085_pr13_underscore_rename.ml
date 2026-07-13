open Alcotest

(** RFC-0085 PR-13 — Underscore-prefix bindings audited file-by-file.

    4 active (PR-12 pattern: misleading _ prefix on used bindings):
       - config_dir_resolver._cached_resolution
       - keeper_tool_surface_ops._keeper_list_cache
       - board_tool_cache._board_list_cache
       - tool_workspace._status_cache
    All renamed (drop _ prefix), callers in same file updated.

    Original test scanned [count_string_literals], which examines only
    [Pconst_string] nodes — identifiers are NOT string literals, so the
    test would pass even if [_xxx] identifiers were reintroduced.
    This revision uses [count_value_bindings ~name], which inspects
    [Ppat_var] nodes (actual identifier bindings). *)

let renamed_identifiers =
  [ "lib/config_dir_resolver/config_dir_resolver.ml", "_cached_resolution", "cached_resolution"
  ; "lib/keeper/keeper_tool_surface_ops.ml", "_keeper_list_cache", "keeper_list_cache"
  ; "lib/board_tool_adapter/board_tool_cache.ml", "_board_list_cache", "board_list_cache"
  ; "lib/tool_workspace.ml", "_status_cache", "status_cache"
  ]
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
    [ ( "active rename"
      , [ test_case "old underscore names gone" `Quick test_renamed_old_names_gone
        ; test_case "new names present" `Quick test_renamed_new_names_present
        ] )
    ]
;;
