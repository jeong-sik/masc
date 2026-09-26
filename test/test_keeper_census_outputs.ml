open Alcotest
open Masc

module Health = Server_routes_http_runtime_health_fleet

let with_workspace f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "keeper-census-outputs-" "" in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous_state;
      Keeper_tool_surface.For_testing.reset_keeper_list_cache ();
      Workspace.invalidate_initialized_cache ();
      Fs_compat.remove_tree base_path;
      Fs_compat.clear_fs ())
    (fun () ->
      let state = Mcp_server.For_testing.create_state ~base_path in
      let config = Mcp_server.workspace_config state in
      ignore (Workspace.init config ~agent_name:None);
      Fs_compat.mkdir_p (Workspace.keepers_runtime_dir config);
      Server_auth.For_testing.restore_server_state (Some state);
      let keeper_ctx : _ Keeper_types_profile.context =
        { config
        ; agent_name = "census-reader"
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
        ; net = Some (Eio.Stdenv.net env)
        ; publication_recovery_provider =
            Masc_test_deps.non_runtime_publication_recovery_provider
        }
      in
      f config keeper_ctx)
;;

let keeper_list ctx =
  match Keeper_tool_surface.dispatch ctx ~name:"masc_keeper_list" ~args:(`Assoc []) with
  | Some result -> result
  | None -> fail "Keeper list did not dispatch"
;;

let pause_status config =
  let ctx : Tool_control.context = { config; agent_name = "census-reader" } in
  match Tool_control.dispatch ctx ~name:"masc_pause_status" ~args:(`Assoc []) with
  | Some result -> result
  | None -> fail "Pause status did not dispatch"
;;

let health_projections =
  [ "owner", Health.keeper_owner_health_json, "ok"
  ; "reaction ledger", Health.keeper_reaction_ledger_health_json, "empty"
  ; "board collection", Health.keeper_board_event_collection_health_json, "ok"
  ]
;;

(* A file at the directory path deterministically fails the real census even
   for a privileged CI user. Preserve the original tree to test recovery
   without a permission race or a cache-expiry sleep. *)
let replace_census_directory config =
  let path = Workspace.keepers_runtime_dir config in
  let retained = path ^ ".fixture-retained" in
  Unix.rename path retained;
  Out_channel.with_open_bin path (fun out -> output_string out "not a directory");
  (* A cold ensure-dir cache raises instead of returning [Error]; read the
     census the way the surfaces do so the expected detail always matches. *)
  let census =
    try Keeper_meta_store.keeper_names_result config with
    | EioCancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printexc.to_string exn)
  in
  let detail =
    match census with
    | Error detail -> detail
    | Ok _ -> fail "the file fixture did not refuse the real Keeper census"
  in
  detail, (fun () -> Sys.remove path; Unix.rename retained path)
;;

let assert_census_failure detail result =
  check bool "the tool does not publish successful empty evidence" false
    (Tool_result.is_success result);
  check bool "the failure class remains typed" true
    (Tool_result.failure_class result = Some Tool_result.Runtime_failure);
  check string "the read failure reaches the caller" detail (Tool_result.message result)
;;

let test_empty_directory_is_a_complete_read () =
  with_workspace @@ fun config keeper_ctx ->
  let listed = keeper_list keeper_ctx in
  check bool "empty list succeeds" true (Tool_result.is_success listed);
  let json = Tool_result.data listed in
  check int "empty list total" 0 Yojson.Safe.Util.(json |> member "total" |> to_int);
  check bool "empty list is complete" false
    Yojson.Safe.Util.(json |> member "truncated" |> to_bool);
  let pause = pause_status config in
  check bool "empty pause census succeeds" true (Tool_result.is_success pause);
  check bool "no pause is known active" false
    Yojson.Safe.Util.(Tool_result.data pause |> member "any_pause_active" |> to_bool);
  List.iter
    (fun (label, project, expected_status) ->
      let json = project () in
      check string (label ^ " readable status") expected_status
        Yojson.Safe.Util.(json |> member "status" |> to_string);
      check int (label ^ " observed empty census") 0
        Yojson.Safe.Util.(json |> member "keeper_count" |> to_int))
    health_projections
;;

let test_unreadable_list_overrides_a_warm_success_cache () =
  with_workspace @@ fun config keeper_ctx ->
  check bool "successful projection warms the real list cache" true
    (Tool_result.is_success (keeper_list keeper_ctx));
  let detail, restore = replace_census_directory config in
  assert_census_failure detail (keeper_list keeper_ctx);
  restore ();
  check bool "restoring the directory allows a complete read again" true
    (Tool_result.is_success (keeper_list keeper_ctx))
;;

let test_unreadable_pause_census_cannot_prove_no_pause () =
  with_workspace @@ fun config _keeper_ctx ->
  let detail, _restore = replace_census_directory config in
  assert_census_failure detail (pause_status config)
;;

let test_unreadable_health_census_is_not_a_healthy_empty_fleet () =
  with_workspace @@ fun config _keeper_ctx ->
  let detail, _restore = replace_census_directory config in
  List.iter
    (fun (label, project, _empty_status) ->
      let json = project () in
      check string (label ^ " status") "unavailable"
        Yojson.Safe.Util.(json |> member "status" |> to_string);
      check bool (label ^ " needs attention") true
        Yojson.Safe.Util.(json |> member "operator_action_required" |> to_bool);
      check bool (label ^ " count is unknown") true
        (Yojson.Safe.Util.member "keeper_count" json = `Null);
      check (list string) (label ^ " reason") [ "keeper_names_unreadable" ]
        Yojson.Safe.Util.(json |> member "status_reasons" |> to_list |> List.map to_string);
      match
        Keeper_snapshot_unread.listing_of_json
          (Yojson.Safe.Util.member "keepers_listing" json)
      with
      | Ok (Keeper_snapshot_unread.Unreadable observed) ->
        check string (label ^ " original read error") detail observed
      | Ok (Keeper_snapshot_unread.Not_listed | Keeper_snapshot_unread.Listed) ->
        fail (label ^ " erased the failed census")
      | Error error -> fail error)
    health_projections
;;

let () =
  run "Keeper census outputs"
    [ "production projections",
      [ test_case "empty directory remains a valid complete census" `Quick
          test_empty_directory_is_a_complete_read
      ; test_case "unreadable list cannot reuse a cached success" `Quick
          test_unreadable_list_overrides_a_warm_success_cache
      ; test_case "pause status refuses an unreadable census" `Quick
          test_unreadable_pause_census_cannot_prove_no_pause
      ; test_case "fleet health retains census failure" `Quick
          test_unreadable_health_census_is_not_a_healthy_empty_fleet
      ]
    ]
;;
