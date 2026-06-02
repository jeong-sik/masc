open Alcotest

(** RFC-0085 PR-16 — Retroactive regression test.

    Original PR-16 (#15484) renamed 9 underscore-prefix bindings in
    [lib/server/server_dashboard_http_core.ml].  All are mutable
    refs/atomics/caches — actively used at runtime, so the [_xxx]
    convention misled readers.  Shipped without test; pin now. *)

let file = "lib/server/server_dashboard_http_core.ml"

let renamed_identifiers =
  [ "_shell_warmed", "shell_warmed"
  ; "_shell_warming", "shell_warming"
  ; "_last_good_shell", "last_good_shell"
  ; "_operator_snapshot_broadcast_ref", "operator_snapshot_broadcast_ref"
  ; "_operator_digest_broadcast_ref", "operator_digest_broadcast_ref"
  ; "_operator_snapshot_cache", "operator_snapshot_cache"
  ; "_operator_digest_cache", "operator_digest_cache"
  ; "_operator_refresh_interval_s", "operator_refresh_interval_s"
  ; "_mission_cache", "mission_cache"
  ]
;;

let test_old_underscore_names_gone () =
  List.iter
    (fun (old_name, _) ->
      let n = Ast_grep.count_value_bindings ~module_path:file ~name:old_name in
      let msg = Printf.sprintf "old underscore name %s should be removed" old_name in
      check int msg 0 n)
    renamed_identifiers
;;

let test_new_names_present () =
  List.iter
    (fun (_, new_name) ->
      let n = Ast_grep.count_value_bindings ~module_path:file ~name:new_name in
      let msg = Printf.sprintf "renamed binding %s must exist" new_name in
      if n < 1 then failf "%s — count=%d" msg n)
    renamed_identifiers
;;

let () =
  run
    "rfc-0085-pr-16-dashboard-http-core-rename"
    [ ( "identifier rename"
      , [ test_case "old underscore names gone" `Quick test_old_underscore_names_gone
        ; test_case "new names present" `Quick test_new_names_present
        ] )
    ]
;;
