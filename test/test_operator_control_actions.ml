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
        ] )
    ; ( "confirmation"
      , [ Alcotest.test_case
            "expired token is rejected"
            `Quick
            Test_operator_control_confirm.test_confirm_rejects_expired_token
        ] )
    ]
;;
