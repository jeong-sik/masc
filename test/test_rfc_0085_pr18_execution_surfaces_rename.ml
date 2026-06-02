open Alcotest

(** RFC-0085 PR-18 — Retroactive regression test.

    Original PR-18 (#15486) renamed 8 underscore-prefix bindings across
    [server_dashboard_http_execution_surfaces.ml] (5),
    [server_dashboard_http_namespace_truth.ml] (2),
    [server_dashboard_http_namespace_truth_support.ml] (1).
    Shipped without test; pin now. *)

let renames =
  [ ( "lib/server/server_dashboard_http_execution_surfaces.ml"
    , "_last_broadcast_hash"
    , "last_broadcast_hash" )
  ; ( "lib/server/server_dashboard_http_execution_surfaces.ml"
    , "_broadcast_hash_mu"
    , "broadcast_hash_mu" )
  ; ( "lib/server/server_dashboard_http_execution_surfaces.ml"
    , "_execution_cache"
    , "execution_cache" )
  ; ( "lib/server/server_dashboard_http_execution_surfaces.ml"
    , "_transport_health_cache"
    , "transport_health_cache" )
  ; ( "lib/server/server_dashboard_http_execution_surfaces.ml"
    , "_broadcast_namespace_truth_ref"
    , "broadcast_namespace_truth_ref" )
  ; ( "lib/server/server_dashboard_http_namespace_truth.ml"
    , "_last_namespace_truth_snapshot_hash"
    , "last_namespace_truth_snapshot_hash" )
  ; ( "lib/server/server_dashboard_http_namespace_truth.ml"
    , "_namespace_truth_snapshot_hash_mu"
    , "namespace_truth_snapshot_hash_mu" )
  ; ( "lib/server/server_dashboard_http_namespace_truth_support.ml"
    , "_last_good_pending_confirm_summary"
    , "last_good_pending_confirm_summary" )
  ]
;;

let test_old_underscore_names_gone () =
  List.iter
    (fun (path, old_name, _) ->
      let n = Ast_grep.count_value_bindings ~module_path:path ~name:old_name in
      let msg = Printf.sprintf "old %s should be removed in %s" old_name path in
      check int msg 0 n)
    renames
;;

let test_new_names_present () =
  List.iter
    (fun (path, _, new_name) ->
      let n = Ast_grep.count_value_bindings ~module_path:path ~name:new_name in
      let msg = Printf.sprintf "renamed %s must exist in %s" new_name path in
      if n < 1 then failf "%s — count=%d" msg n)
    renames
;;

let () =
  run
    "rfc-0085-pr-18-execution-surfaces-rename"
    [ ( "identifier rename"
      , [ test_case "old underscore names gone" `Quick test_old_underscore_names_gone
        ; test_case "new names present" `Quick test_new_names_present
        ] )
    ]
;;
