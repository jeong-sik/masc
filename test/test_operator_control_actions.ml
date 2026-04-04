open Masc_mcp
open Test_operator_control_support

let test_task_inject_executes_immediately () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let ctx = operator_ctx env sw config "operator" in
      let action_json =
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "operator");
              ("action_type", `String "task_inject");
              ("target_type", `String "namespace");
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
      let tasks = Room.get_tasks_raw config in
      Alcotest.(check int) "task injected" 1 (List.length tasks))

let test_digest_defaults_to_namespace_target () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let ctx = operator_ctx env sw config "operator" in
      let digest_json =
        match Operator_control.digest_json ctx with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "default target_type" "namespace"
        Yojson.Safe.Util.(digest_json |> member "target_type" |> to_string))

let test_team_turn_falls_back_to_session_actor () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      let session_id = start_session_exn (team_ctx env sw config "owner") in
      let ctx = operator_ctx env sw config "dashboard" in
      let action_json =
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "dashboard");
              ("action_type", `String "team_turn");
              ("target_type", `String "team_session");
              ("target_id", `String session_id);
              ("payload", `Assoc [ ("turn_kind", `String "note"); ("message", `String "operator note") ]);
            ])
      in
      let action_json =
        match action_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "delegated tool" "masc_team_session_step"
        Yojson.Safe.Util.(action_json |> member "delegated_tool" |> to_string);
      let delegated = action_json |> Yojson.Safe.Util.member "result" in
      Alcotest.(check bool) "override true" true
        Yojson.Safe.Util.(delegated |> member "operator_override" |> to_bool);
      Alcotest.(check string) "result delegated tool" "masc_team_session_step"
        Yojson.Safe.Util.(delegated |> member "delegated_tool" |> to_string);
      let events = Team_session_store.read_events ~max_events:20 config session_id in
      Alcotest.(check bool) "event recorded" true (List.length events > 0))

let test_team_note_records_action_log () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      let session_id = start_session_exn (team_ctx env sw config "owner") in
      let ctx =
        operator_ctx ~mcp_session_id:"remote-session-1" env sw config "dashboard"
      in
      let action_json =
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "dashboard");
              ("action_type", `String "team_note");
              ("target_id", `String session_id);
              ("payload", `Assoc [ ("message", `String "operator note") ]);
            ])
      in
      let action_json =
        match action_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check bool) "no confirm required" false
        Yojson.Safe.Util.(action_json |> member "confirm_required" |> to_bool);
      Alcotest.(check string) "delegated tool" "masc_team_session_step"
        Yojson.Safe.Util.(action_json |> member "delegated_tool" |> to_string);
      let snapshot = Operator_control.snapshot_json ~actor:"dashboard" ctx in
      let recent_actions =
        snapshot |> Yojson.Safe.Util.member "recent_actions" |> Yojson.Safe.Util.to_list
      in
      Alcotest.(check int) "recent action count" 1 (List.length recent_actions);
      let entry = List.hd recent_actions in
      Alcotest.(check string) "action_type" "team_note"
        Yojson.Safe.Util.(entry |> member "action_type" |> to_string);
      Alcotest.(check string) "remote session id" "remote-session-1"
        Yojson.Safe.Util.(entry |> member "remote_session_id" |> to_string))

let test_team_broadcast_records_event () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      let session_id = start_session_exn (team_ctx env sw config "owner") in
      let ctx = operator_ctx env sw config "dashboard" in
      let action_json =
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "dashboard");
              ("action_type", `String "team_broadcast");
              ("target_id", `String session_id);
              ("payload", `Assoc [ ("message", `String "broadcast to session") ]);
            ])
      in
      let action_json =
        match action_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "delegated tool" "masc_team_session_step"
        Yojson.Safe.Util.(action_json |> member "delegated_tool" |> to_string);
      Alcotest.(check bool) "result present" true
        (Yojson.Safe.Util.member "result" action_json <> `Null);
      let events = Team_session_store.read_events ~max_events:20 config session_id in
      Alcotest.(check bool) "event recorded" true (List.length events > 0))

let test_team_task_inject_requires_confirm_then_executes () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      let session_id = start_session_exn (team_ctx env sw config "owner") in
      let ctx = operator_ctx env sw config "dashboard" in
      let action_json =
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "dashboard");
              ("action_type", `String "team_task_inject");
              ("target_id", `String session_id);
              ( "payload",
                `Assoc
                  [
                    ("title", `String "Injected session task");
                    ("description", `String "created by remote operator");
                    ("priority", `Int 1);
                  ] );
            ])
      in
      let action_json =
        match action_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      let confirm_token =
        Yojson.Safe.Util.(action_json |> member "confirm_token" |> to_string)
      in
      Alcotest.(check bool) "confirm required" true
        Yojson.Safe.Util.(action_json |> member "confirm_required" |> to_bool);
      Alcotest.(check string) "delegated tool" "masc_team_session_step"
        Yojson.Safe.Util.(action_json |> member "delegated_tool" |> to_string);
      let confirm_json =
        Operator_control.confirm_json ctx
          (`Assoc [ ("actor", `String "dashboard"); ("confirm_token", `String confirm_token) ])
      in
      let confirm_json =
        match confirm_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check bool) "delegated tool result present" true
        (Yojson.Safe.Util.member "delegated_tool_result" confirm_json <> `Null);
      Alcotest.(check string) "delegated tool result" "masc_team_session_step"
        Yojson.Safe.Util.
          (confirm_json |> member "delegated_tool_result" |> member "delegated_tool"
         |> to_string);
      let pending_confirms =
        Operator_control.snapshot_json ~actor:"dashboard" ctx
        |> Yojson.Safe.Util.member "pending_confirms"
        |> Yojson.Safe.Util.to_list
      in
      Alcotest.(check int) "pending confirm cleared" 0 (List.length pending_confirms))

let test_team_worker_spawn_batch_requires_confirm_then_executes () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      let session_id = start_session_exn (team_ctx env sw config "owner") in
      let ctx = operator_ctx env sw config "dashboard" in
      let action_json =
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "dashboard");
              ("action_type", `String "team_worker_spawn_batch");
              ("target_id", `String session_id);
              ( "payload",
                `Assoc
                  [
                    ( "spawn_batch",
                      `List
                        [
                          `Assoc
                            [
                              ("spawn_prompt", `String "record one worker turn");
                              ("spawn_role", `String "replacement");
                              ("spawn_timeout_seconds", `Int 1);
                            ];
                        ] );
                    ("wait_mode", `String "blocking");
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
      Alcotest.(check string) "delegated tool" "masc_team_session_step"
        Yojson.Safe.Util.(action_json |> member "delegated_tool" |> to_string);
      let confirm_token =
        Yojson.Safe.Util.(action_json |> member "confirm_token" |> to_string)
      in
      let confirm_json =
        Operator_control.confirm_json ctx
          (`Assoc [ ("actor", `String "dashboard"); ("confirm_token", `String confirm_token) ])
      in
      let confirm_json =
        match confirm_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      let delegated_result =
        Yojson.Safe.Util.member "delegated_tool_result" confirm_json
      in
      Alcotest.(check string) "delegated tool result" "masc_team_session_step"
        Yojson.Safe.Util.(delegated_result |> member "delegated_tool" |> to_string);
      let events = Team_session_store.read_events ~max_events:20 config session_id in
      Alcotest.(check bool) "team_step_spawn recorded" true
        (List.exists
           (fun json ->
             Yojson.Safe.Util.(json |> member "event_type" |> to_string)
             = "team_step_spawn")
           events);
      let spawn_event =
        match
          List.find_opt
            (fun json ->
              Yojson.Safe.Util.(json |> member "event_type" |> to_string)
              = "team_step_spawn")
            events
        with
        | Some json -> json
        | None -> Alcotest.fail "expected team_step_spawn event"
      in
      Alcotest.(check string) "spawn actor falls back to owner" "owner"
        Yojson.Safe.Util.(spawn_event |> member "detail" |> member "actor" |> to_string))

let review_item_from_room_digest ctx =
  let digest =
    match Operator_control.digest_json ~actor:"dashboard" ctx with
    | Ok json -> json
    | Error err -> Alcotest.fail err
  in
  match Yojson.Safe.Util.(digest |> member "review_queue" |> to_list) with
  | item :: _ -> item
  | [] -> Alcotest.fail "expected review_queue item"

let test_review_resolve_hides_matching_item () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "dashboard"));
      let ctx = operator_ctx env sw config "dashboard" in
      (match
         Operator_control.action_json ctx
           (`Assoc
             [
               ("actor", `String "dashboard");
               ("action_type", `String "namespace_pause");
               ("target_type", `String "namespace");
               ("payload", `Assoc [ ("reason", `String "queue test") ]);
             ])
       with
      | Ok _ -> ()
      | Error err -> Alcotest.fail err);
      let item = review_item_from_room_digest ctx in
      let action_json =
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "dashboard");
              ("action_type", `String "review_resolve");
              ("target_type", `String "review_item");
              ("target_id", item |> Yojson.Safe.Util.member "id");
              ( "payload",
                `Assoc
                  [
                    ("item_id", item |> Yojson.Safe.Util.member "id");
                    ("fingerprint", item |> Yojson.Safe.Util.member "fingerprint");
                    ("item_target_type", item |> Yojson.Safe.Util.member "target_type");
                    ("item_target_id", item |> Yojson.Safe.Util.member "target_id");
                    ("recommended_action_type",
                      item |> Yojson.Safe.Util.member "recommended_action"
                      |> Yojson.Safe.Util.member "action_type");
                    ("reason", `String "acknowledged by operator");
                  ] );
            ])
      in
      let action_json =
        match action_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "review decision" "resolved"
        Yojson.Safe.Util.
          (action_json |> member "result" |> member "result" |> member "decision"
         |> to_string);
      let digest_after =
        match Operator_control.digest_json ~actor:"dashboard" ctx with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check int) "active review queue cleared" 0
        Yojson.Safe.Util.(digest_after |> member "review_queue" |> to_list |> List.length);
      Alcotest.(check int) "recent review recorded" 1
        Yojson.Safe.Util.(digest_after |> member "recent_reviews" |> to_list |> List.length))

let test_review_defer_moves_item_to_deferred_queue () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "dashboard"));
      let ctx = operator_ctx env sw config "dashboard" in
      (match
         Operator_control.action_json ctx
           (`Assoc
             [
               ("actor", `String "dashboard");
               ("action_type", `String "namespace_pause");
               ("target_type", `String "namespace");
               ("payload", `Assoc [ ("reason", `String "queue defer test") ]);
             ])
       with
      | Ok _ -> ()
      | Error err -> Alcotest.fail err);
      let item = review_item_from_room_digest ctx in
      (match
         Operator_control.action_json ctx
           (`Assoc
             [
               ("actor", `String "dashboard");
               ("action_type", `String "review_defer");
               ("target_type", `String "review_item");
               ("target_id", item |> Yojson.Safe.Util.member "id");
               ( "payload",
                 `Assoc
                   [
                     ("item_id", item |> Yojson.Safe.Util.member "id");
                     ("fingerprint", item |> Yojson.Safe.Util.member "fingerprint");
                     ("item_target_type", item |> Yojson.Safe.Util.member "target_type");
                     ("item_target_id", item |> Yojson.Safe.Util.member "target_id");
                     ("recommended_action_type",
                       item |> Yojson.Safe.Util.member "recommended_action"
                       |> Yojson.Safe.Util.member "action_type");
                     ("reason", `String "defer until later");
                   ] );
             ])
       with
      | Ok _ -> ()
      | Error err -> Alcotest.fail err);
      let digest_after =
        match Operator_control.digest_json ~actor:"dashboard" ctx with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check int) "active review queue empty" 0
        Yojson.Safe.Util.(digest_after |> member "review_queue" |> to_list |> List.length);
      Alcotest.(check int) "deferred review queue has item" 1
        Yojson.Safe.Util.(digest_after |> member "deferred_queue" |> to_list |> List.length))
