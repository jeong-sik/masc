open Masc_mcp
open Test_operator_control_support

let test_snapshot_keeper_tool_audit_fallback () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive "audit-keeper";
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
       let config = Coord.default_config base_dir in
       ignore (Coord.init config ~agent_name:(Some "operator"));
       let keeper_ctx : _ Tool_keeper.context =
         { config
         ; agent_name = "operator"
         ; sw
         ; clock = Eio.Stdenv.clock env
         ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
         ; net = None
         }
       in
       let keeper_name = "audit-keeper" in
       let ok, _ =
         dispatch_keeper_exn
           keeper_ctx
           ~name:"masc_keeper_up"
           ~args:
             (`Assoc
               [ "name", `String keeper_name
               ; "goal", `String "Expose dashboard fallback keeper audit"
               ; "proactive_enabled", `Bool false
               ; "autoboot_enabled", `Bool false
               ])
       in
       Alcotest.(check bool) "keeper up ok" true ok;
       let open Yojson.Safe.Util in
       let rec load_keeper_snapshot attempts_left =
         let snapshot =
           Operator_control.snapshot_json
             ~include_messages:false
             ~include_keepers:true
             (operator_ctx env sw config "operator")
         in
         match
           snapshot
           |> member "keepers"
           |> member "items"
           |> to_list
           |> List.find_opt (fun row ->
             row |> member "name" |> to_string = keeper_name)
         with
         | Some keeper -> keeper
         | None when attempts_left > 0 ->
           Unix.sleepf 0.05;
           load_keeper_snapshot (attempts_left - 1)
         | None ->
           Alcotest.failf
             "keeper %s missing from snapshot: %s"
             keeper_name
             (Yojson.Safe.to_string snapshot)
       in
       let keeper = load_keeper_snapshot 10 in
       Alcotest.(check string)
         "durable keeper is idle before first turn after keeper_up"
         "idle"
         (keeper |> member "status" |> to_string);
       Alcotest.(check bool)
         "allowed tool fallback present"
         true
         ((keeper |> member "allowed_tool_names" |> to_list) <> []);
       let tool_audit_source =
         keeper |> member "tool_audit_source" |> to_string_option
       in
       Alcotest.(check bool)
         "tool audit source absent or known"
         true
         (match tool_audit_source with
          | None -> true
          | Some s -> List.mem s [ "keeper_metrics"; "keeper_decision_log" ]);
       Alcotest.(check bool)
         "tool audit count zero or absent before first turn"
         true
         (match keeper |> member "latest_tool_call_count" with
          | `Null -> true
          | `Int 0 -> true
          | _ -> false);
       Alcotest.(check bool)
         "tool audit names remain empty"
         true
         ((keeper |> member "latest_tool_names" |> to_list) = []);
       Alcotest.(check bool)
         "diagnostic removed from snapshot"
         true
         (keeper |> member "diagnostic" = `Null);
       let ok, _ =
         dispatch_keeper_exn
           keeper_ctx
           ~name:"masc_keeper_down"
           ~args:(`Assoc [ "name", `String keeper_name ])
       in
       Alcotest.(check bool) "keeper down ok" true ok)
;;

let test_snapshot_keeper_tool_audit_uses_decision_log () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive "audit-keeper-decision";
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
       let config = Coord.default_config base_dir in
       ignore (Coord.init config ~agent_name:(Some "operator"));
       let keeper_ctx : _ Tool_keeper.context =
         { config
         ; agent_name = "operator"
         ; sw
         ; clock = Eio.Stdenv.clock env
         ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
         ; net = None
         }
       in
       let keeper_name = "audit-keeper-decision" in
       let ok, _ =
         dispatch_keeper_exn
           keeper_ctx
           ~name:"masc_keeper_up"
           ~args:
             (`Assoc
               [ "name", `String keeper_name
               ; "goal", `String "Expose dashboard decision audit"
               ; "proactive_enabled", `Bool false
               ; "autoboot_enabled", `Bool false
               ])
       in
       Alcotest.(check bool) "keeper up ok" true ok;
       Fs_compat.append_jsonl
         (Keeper_types.keeper_decision_log_path config keeper_name)
         (`Assoc
           [ "ts", `String (Masc_domain.now_iso ())
           ; "selected_mode", `String "text_response"
           ; "action_source", `String "fallback_after_validation_failure"
           ; "tool_call_count", `Int 0
           ; "tools_used", `List []
           ]);
       let open Yojson.Safe.Util in
       let rec load_keeper_snapshot attempts_left =
         let snapshot =
           Operator_control.snapshot_json
             ~include_messages:false
             ~include_keepers:true
             (operator_ctx env sw config "operator")
         in
         match
           snapshot
           |> member "keepers"
           |> member "items"
           |> to_list
           |> List.find_opt (fun row ->
             row |> member "name" |> to_string = keeper_name)
         with
         | Some keeper -> keeper
         | None when attempts_left > 0 ->
           Unix.sleepf 0.05;
           load_keeper_snapshot (attempts_left - 1)
         | None ->
           Alcotest.failf
             "keeper %s missing from snapshot: %s"
             keeper_name
             (Yojson.Safe.to_string snapshot)
       in
       let keeper = load_keeper_snapshot 10 in
       Alcotest.(check string)
         "decision log source exposed"
         "keeper_decision_log"
         (keeper |> member "tool_audit_source" |> to_string);
       Alcotest.(check string)
         "decision log action source exposed"
         "fallback_after_validation_failure"
         (keeper |> member "latest_action_source" |> to_string);
       Alcotest.(check int)
         "decision log zero tool count exposed"
         0
         (keeper |> member "latest_tool_call_count" |> to_int);
       Alcotest.(check bool)
         "decision log names remain empty"
         true
         ((keeper |> member "latest_tool_names" |> to_list) = []))
;;
