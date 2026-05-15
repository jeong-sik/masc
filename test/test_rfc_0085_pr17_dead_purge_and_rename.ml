open Alcotest

(** RFC-0085 PR-17 — Retroactive regression test.

    Original PR-17 (#15485) deleted 4 truly-dead functions (~250 LOC)
    and renamed 2 active bindings.  Shipped without test; pin now. *)

let dead_in_dashboard_mission =
  [ "_build_session_context"; "_build_briefs_from_sessions" ]
;;

let dead_in_channel_gate_metrics =
  [ "_binding_snapshot"; "_effective_attempt_count" ]
;;

let renamed_in_coord =
  ( "lib/coord/coord_utils_paths_backend.ml"
  , "_shared_pubsub"
  , "shared_pubsub" )
;;

let renamed_in_diagnostics =
  ( "lib/server_base_path_diagnostics.ml"
  , "_logged_once"
  , "logged_once" )
;;

let test_dashboard_mission_dead_gone () =
  let path = "lib/dashboard/dashboard_mission.ml" in
  List.iter
    (fun name ->
      let n = Ast_grep.count_value_bindings ~module_path:path ~name in
      let msg = Printf.sprintf "dead %s should be deleted in %s" name path in
      check int msg 0 n)
    dead_in_dashboard_mission
;;

let test_channel_gate_metrics_dead_gone () =
  let path = "lib/gate/channel_gate_metrics.ml" in
  List.iter
    (fun name ->
      let n = Ast_grep.count_value_bindings ~module_path:path ~name in
      let msg = Printf.sprintf "dead %s should be deleted in %s" name path in
      check int msg 0 n)
    dead_in_channel_gate_metrics
;;

let test_renamed_old_names_gone () =
  List.iter
    (fun (path, old_name, _) ->
      let n = Ast_grep.count_value_bindings ~module_path:path ~name:old_name in
      let msg = Printf.sprintf "old %s should be gone in %s" old_name path in
      check int msg 0 n)
    [ renamed_in_coord; renamed_in_diagnostics ]
;;

let test_renamed_new_names_present () =
  List.iter
    (fun (path, _, new_name) ->
      let n = Ast_grep.count_value_bindings ~module_path:path ~name:new_name in
      let msg = Printf.sprintf "new %s must exist in %s" new_name path in
      if n < 1 then failf "%s — count=%d" msg n)
    [ renamed_in_coord; renamed_in_diagnostics ]
;;

let () =
  run
    "rfc-0085-pr-17-dead-purge-and-rename"
    [ ( "dead removal"
      , [ test_case "dashboard_mission dead gone" `Quick test_dashboard_mission_dead_gone
        ; test_case
            "channel_gate_metrics dead gone"
            `Quick
            test_channel_gate_metrics_dead_gone
        ] )
    ; ( "rename"
      , [ test_case "old underscore names gone" `Quick test_renamed_old_names_gone
        ; test_case "new names present" `Quick test_renamed_new_names_present
        ] )
    ]
;;
