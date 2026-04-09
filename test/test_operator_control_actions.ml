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
