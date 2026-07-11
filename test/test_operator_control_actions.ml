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

let test_task_inject_executes_immediately () =
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
      Alcotest.(check bool) "confirm required" false
        Yojson.Safe.Util.(action_json |> member "confirm_required" |> to_bool);
      Alcotest.(check bool) "no confirm token" true
        (Yojson.Safe.Util.member "confirm_token" action_json = `Null);
      let snapshot = Operator_control.snapshot_json ~actor:"operator" ctx in
      let pending_confirms =
        snapshot |> Yojson.Safe.Util.member "pending_confirms"
        |> Yojson.Safe.Util.to_list
      in
      Alcotest.(check int) "pending confirm count" 0 (List.length pending_confirms);
      Alcotest.(check bool) "result present" true
        (Yojson.Safe.Util.member "result" action_json <> `Null);
      let tasks = Workspace.get_tasks_raw config in
      Alcotest.(check int) "task injected" 1 (List.length tasks))

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
        (Operator_approval.is_allowed action_type);
      Alcotest.(check bool)
        (action_type ^ " not confirm-required")
        false
        (Operator_approval.confirm_required action_type))
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

let test_keeper_sandbox_stop_operator_dispatch_is_wired () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let ctx =
        Keeper_tool_boundary.create
          ~config
          ~agent_name:"operator"
          ~sw
          ~clock:(Eio.Stdenv.clock env)
          ~proc_mgr:(Some (Eio.Stdenv.process_mgr env))
          ~net:(Some (Eio.Stdenv.net env))
      in
      let dispatch_exn args =
        match
          Keeper_tool_boundary.dispatch
            ctx
            ~name:"masc_keeper_sandbox_stop"
            ~args
        with
        | Some result -> result
        | None -> Alcotest.fail "sandbox stop has a schema/tag but no handler"
      in
      let check_failure_class label expected result =
        Alcotest.(check bool)
          label
          true
          (Tool_result.failure_class result = Some expected)
      in
      [ `Assoc []
      ; `Assoc
          [ "name", `String "one"
          ; "fleet", `Bool true
          ; "container_kind", `String "all"
          ]
      ; `Assoc [ "name", `String "one" ]
      ; `Assoc
          [ "name", `String "one"
          ; "container_kind", `String "invalid"
          ]
      ; `Assoc
          [ "name", `String "victim!"
          ; "container_kind", `String "all"
          ]
      ; `Assoc
          [ "name", `String "one"
          ; "fleet", `Bool false
          ; "container_kind", `String "all"
          ]
      ; `Assoc
          [ "fleet", `Bool true
          ; "container_kind", `String "all"
          ; "cleanup_stale_fleet", `Bool true
          ]
      ]
      |> List.iteri (fun index args ->
        check_failure_class
          (Printf.sprintf "invalid stop contract %d is rejected" index)
          Tool_result.Workflow_rejection
          (dispatch_exn args));
      let fake_docker_env = "MASC_TEST_FAKE_DOCKER_PATH" in
      let original_fake_docker = Sys.getenv_opt fake_docker_env in
      let failed_stop =
        Fun.protect
          ~finally:(fun () ->
            Unix.putenv
              fake_docker_env
              (Option.value original_fake_docker ~default:""))
          (fun () ->
            Unix.putenv fake_docker_env "/definitely/missing/masc-docker";
            dispatch_exn
              (`Assoc
                [ "fleet", `Bool true
                ; "container_kind", `String "all"
                ]))
      in
      check_failure_class
        "Docker stop failures are not reported as success"
        Tool_result.Runtime_failure
        failed_stop;
      Alcotest.(check (option string))
        "failed stop payload is explicitly error"
        (Some "error")
        (match Tool_result.data failed_stop with
         | `Assoc fields ->
           (match List.assoc_opt "status" fields with
            | Some (`String status) -> Some status
            | _ -> None)
         | _ -> None))

(* review_queue / deferred_queue / review_summary fields were emitted for
   a retired dashboard surface; the producers (split_review_items,
   *_review_item) were also removed. Review decisions still reach the UI
   via [recent_reviews]. *)

let () =
  Alcotest.run
    "operator_control_actions"
    [ ( "actions"
      , [ Alcotest.test_case
            "task inject executes immediately"
            `Quick
            test_task_inject_executes_immediately
        ; Alcotest.test_case
            "digest defaults to workspace target"
            `Quick
            test_digest_defaults_to_workspace_target
        ; Alcotest.test_case
            "legacy action aliases are rejected"
            `Quick
            test_operator_action_rejects_legacy_action_aliases
        ; Alcotest.test_case
            "sandbox stop operator dispatch is wired"
            `Quick
            test_keeper_sandbox_stop_operator_dispatch_is_wired
        ] )
    ; ( "confirmation"
      , [ Alcotest.test_case
            "expired token is rejected"
            `Quick
            Test_operator_control_confirm.test_confirm_rejects_expired_token
        ] )
    ]
;;
