module Types = Masc_domain

open Masc
open Test_operator_control_support

let claim_and_start config ~agent_name ~task_id =
  (match
     Workspace.transition_task_r config ~agent_name ~task_id ~action:Masc_domain.Claim ()
   with
  | Ok _ -> ()
  | Error err -> Alcotest.fail (Masc_domain.show_masc_error err));
  match
    Workspace.transition_task_r config ~agent_name ~task_id ~action:Masc_domain.Start ()
  with
  | Ok _ -> ()
  | Error err -> Alcotest.fail (Masc_domain.show_masc_error err)

let test_task_inject_executes_after_confirmation () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      (* See test setup: workspace init side effect is the fixture under test. *)
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let ctx = operator_ctx env sw config "operator" in
      let action_json =
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "operator");
              ("action_type", `String "task_inject");
              ( "target_type"
              , `String Operator_action_constants.workspace_target_type );
              ( "payload",
                `Assoc
                  [
                    ("title", `String "Injected task");
                    ("description", `String "created by operator");
                    ("priority", `Int 1);
                  ] );
            ])
      in
      let action_json =
        match action_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check bool) "confirm required" true
        Yojson.Safe.Util.(action_json |> member "confirm_required" |> to_bool);
      let confirm_token =
        Yojson.Safe.Util.(action_json |> member "confirm_token" |> to_string)
      in
      let snapshot = Operator_control.snapshot_json ~actor:"operator" ctx in
      let pending_confirms =
        snapshot |> Yojson.Safe.Util.member "pending_confirms"
        |> Yojson.Safe.Util.to_list
      in
      Alcotest.(check int) "pending confirm count" 1 (List.length pending_confirms);
      Alcotest.(check bool) "result absent before confirmation" true
        (Yojson.Safe.Util.member "result" action_json = `Null);
      let tasks = Workspace.get_tasks_raw config in
      Alcotest.(check int) "task not injected before confirmation" 0
        (List.length tasks);
      let confirm_json =
        Operator_control.confirm_json ctx
          (`Assoc
            [
              ("actor", `String "operator");
              ("confirm_token", `String confirm_token);
              ("decision", `String "confirm");
            ])
      in
      let confirm_json =
        match confirm_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "confirmation decision" "confirm"
        Yojson.Safe.Util.(confirm_json |> member "decision" |> to_string);
      Alcotest.(check bool) "result present after confirmation" true
        (Yojson.Safe.Util.member "result" confirm_json <> `Null);
      let snapshot = Operator_control.snapshot_json ~actor:"operator" ctx in
      let pending_confirms =
        snapshot |> Yojson.Safe.Util.member "pending_confirms"
        |> Yojson.Safe.Util.to_list
      in
      Alcotest.(check int) "pending confirm removed" 0
        (List.length pending_confirms);
      let tasks = Workspace.get_tasks_raw config in
      Alcotest.(check int) "task injected after confirmation" 1
        (List.length tasks))

let test_digest_defaults_to_workspace_target () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let ctx = operator_ctx env sw config "operator" in
      let digest_json =
        match Operator_control.digest_json ctx with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string)
        "default target_type"
        Operator_action_constants.workspace_target_type
        Yojson.Safe.Util.(digest_json |> member "target_type" |> to_string))

let test_operator_action_rejects_legacy_action_aliases () =
  let retired_actions =
    [
      "autonomy_tick";
      "keeper_msg";
      "team_note";
      "team_broadcast";
      "team_task_inject";
      "team_worker_spawn_batch";
      "team_stop";
    ]
  in
  List.iter
    (fun action_type ->
      Alcotest.(check bool)
        (action_type ^ " not allowed")
        false
        (Operator_action_catalog.is_allowed action_type);
      Alcotest.(check bool)
        (action_type ^ " not confirm-required")
        false
        (Operator_action_catalog.requires_confirmation action_type))
    retired_actions;
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let ctx = operator_ctx env sw config "operator" in
      List.iter
        (fun action_type ->
          match
            Operator_control.action_json ctx
              (`Assoc
                [
                  ("actor", `String "operator");
                  ("action_type", `String action_type);
                  ("payload", `Assoc []);
                ])
          with
          | Ok _ -> Alcotest.failf "%s should be rejected" action_type
          | Error message ->
              Alcotest.(check string)
                (action_type ^ " rejection")
                ("unsupported action_type: " ^ action_type)
                message)
        retired_actions)

let test_operator_task_recovery_tool_is_strict_and_executes_exact_cas () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Eio.Switch.on_release sw (fun () -> cleanup_dir base_dir);
  let config = Workspace.default_config base_dir in
  ignore (Workspace.init config ~agent_name:(Some "claude"));
  let claude =
    match Workspace.get_agents_raw config with
    | [ agent ] -> agent.Masc_domain.name
    | agents ->
      Alcotest.failf "expected one initialized agent, got %d" (List.length agents)
  in
  ignore
    (Workspace.add_task
       config
       ~title:"Operator tool recovery"
       ~priority:1
       ~description:"");
  (match Workspace.claim_task_r config ~agent_name:claude ~task_id:"task-001" () with
   | Ok _ -> ()
   | Error err -> Alcotest.fail (Masc_domain.masc_error_to_string err));
  let ctx : _ Operator_tool.context =
    { config
    ; agent_name = "operator"
    ; sw
    ; clock = Eio.Stdenv.clock env
    ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
    ; net = Some (Eio.Stdenv.net env)
    ; delegated_dispatch = None
    ; mcp_session_id = None
    }
  in
  let snapshot =
    match
      Operator_tool.dispatch
        ctx
        ~name:"masc_operator_snapshot"
        ~args:(`Assoc [])
    with
    | Some result when Tool_result.is_success result -> Tool_result.data result
    | Some result -> Alcotest.fail (Tool_result.message result)
    | None -> Alcotest.fail "operator snapshot dispatch missing"
  in
  let task_ownership =
    Yojson.Safe.Util.(snapshot |> member "workspace" |> member "task_ownership")
  in
  let observed_version =
    Yojson.Safe.Util.(task_ownership |> member "backlog_version" |> to_int)
  in
  let observed_assignee =
    match Yojson.Safe.Util.(task_ownership |> member "items" |> to_list) with
    | [ item ] -> Yojson.Safe.Util.(item |> member "assignee" |> to_string)
    | items ->
      Alcotest.failf
        "expected one operator-visible owned task, got %d"
        (List.length items)
  in
  Alcotest.(check string) "snapshot exposes exact persisted owner" claude
    observed_assignee;
  let command extra_fields =
    `Assoc
      ([ "schema", `String Operator_task_recovery_command.tool_command_schema
       ; "task_id", `String "task-001"
       ; "expected_assignee", `String observed_assignee
       ; "expected_version", `Int observed_version
       ; "reason", `String "owner runtime cannot resume"
       ]
       @ extra_fields)
  in
  let invalid =
    match
      Operator_tool.dispatch
        ctx
        ~name:"masc_operator_task_recovery_resolve"
        ~args:(command [ "heuristic_timeout_sec", `Int 300 ])
    with
    | Some result -> result
    | None -> Alcotest.fail "operator task recovery dispatch missing"
  in
  Alcotest.(check bool) "unknown heuristic field rejected" true
    (Tool_result.is_failed invalid);
  let valid =
    match
      Operator_tool.dispatch
        ctx
        ~name:"masc_operator_task_recovery_resolve"
        ~args:(command [])
    with
    | Some result -> result
    | None -> Alcotest.fail "operator task recovery dispatch missing"
  in
  Alcotest.(check bool) "exact recovery succeeds" true
    (Tool_result.is_success valid);
  Alcotest.(check string) "tool reports todo" "todo"
    Yojson.Safe.Util.(Tool_result.data valid |> member "status" |> to_string);
  Alcotest.(check bool) "operator recovery audit recorded" true
    Yojson.Safe.Util.
      (Tool_result.data valid |> member "audit" |> member "recorded" |> to_bool);
  let task =
    match Workspace.get_tasks_raw config with
    | [ task ] -> task
    | tasks ->
      Alcotest.failf "expected one task after recovery, got %d" (List.length tasks)
  in
  Alcotest.(check string) "task recovered to todo" "todo"
    (Masc_domain.task_status_to_string task.task_status)

(* review_queue / deferred_queue / review_summary fields were emitted for
   a retired dashboard surface; the producers (split_review_items,
   *_review_item) were also removed. Review decisions still reach the UI
   via [recent_reviews]. *)

let () =
  Alcotest.run
    "operator_control_actions"
    [ ( "actions"
      , [ Alcotest.test_case
            "task inject executes after confirmation"
            `Quick
            test_task_inject_executes_after_confirmation
        ; Alcotest.test_case
            "digest defaults to workspace target"
            `Quick
            test_digest_defaults_to_workspace_target
        ; Alcotest.test_case
            "legacy action aliases are rejected"
            `Quick
            test_operator_action_rejects_legacy_action_aliases
        ; Alcotest.test_case
            "task recovery tool is strict and exact"
            `Quick
            test_operator_task_recovery_tool_is_strict_and_executes_exact_cas
        ] )
    ; ( "confirmation"
      , [ Alcotest.test_case
            "expired token is rejected"
            `Quick
            Test_operator_control_confirm.test_confirm_rejects_expired_token
        ] )
    ]
;;
