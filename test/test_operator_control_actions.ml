open Masc_mcp
open Test_operator_control_support

module CT = Masc_mcp.Cdal_types

let make_review_required_verdict ?(run_id = "review-run-001") () :
    CT.contract_verdict =
  let gap : CT.completeness_gap =
    {
      artifact = "evidence/review_warning.json";
      reason =
        "review_requirement present but only warning-style review evidence exists";
      impact = CT.Blocks_verdict;
    }
  in
  let basis_input =
    Printf.sprintf "%s|%s|%s"
      "md5:review-contract"
      CT.loader_semantics_version_phase1
      CT.schema_compat_mode_v1
  in
  let basis_hash = "md5:" ^ (Digest.string basis_input |> Digest.to_hex) in
  let verdict_without_hash : CT.contract_verdict =
    {
      run_id;
      contract_id = "md5:review-contract";
      claim_scope = CT.claim_scope_phase1;
      judgment_basis_hash = basis_hash;
      judgment_hash = "";
      loader_semantics_version = CT.loader_semantics_version_phase1;
      schema_compat_mode = CT.schema_compat_mode_v1;
      status = CT.Inconclusive;
      findings = [];
      completeness_gaps = [ gap ];
      check_results = [];
    }
  in
  let judgment_hash = CT.compute_judgment_hash verdict_without_hash in
  { verdict_without_hash with judgment_hash }

let claim_and_start config ~agent_name ~task_id =
  (match
     Coord.transition_task_r config ~agent_name ~task_id ~action:Types.Claim ()
   with
  | Ok _ -> ()
  | Error err -> Alcotest.fail (Types.show_masc_error err));
  match
    Coord.transition_task_r config ~agent_name ~task_id ~action:Types.Start ()
  with
  | Ok _ -> ()
  | Error err -> Alcotest.fail (Types.show_masc_error err)

let test_task_inject_executes_immediately () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
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
      let tasks = Coord.get_tasks_raw config in
      Alcotest.(check int) "task injected" 1 (List.length tasks))

let test_digest_defaults_to_namespace_target () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let ctx = operator_ctx env sw config "operator" in
      let digest_json =
        match Operator_control.digest_json ctx with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "default target_type" "root"
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

let test_cdal_review_requirement_appears_in_review_queue () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "dashboard"));
      ignore (Coord.join config ~agent_name:"worker" ~capabilities:[] ());
      let ctx = operator_ctx env sw config "dashboard" in
      let task_id =
        let _ =
          Coord.add_task config ~title:"Review required task" ~priority:2
            ~description:"needs verification routing"
        in
        match Coord.read_backlog config |> fun backlog -> backlog.tasks with
        | task :: _ -> task.id
        | [] -> Alcotest.fail "expected task"
      in
      claim_and_start config ~agent_name:"worker" ~task_id;
      Cdal_eval_v1.persist
        ~base_dir:(Filename.concat base_dir "data/cdal_verdicts")
        ~task_id
        (make_review_required_verdict ());
      let item = review_item_from_room_digest ctx in
      Alcotest.(check string) "kind" "cdal_review_requirement"
        Yojson.Safe.Util.(item |> member "kind" |> to_string);
      Alcotest.(check string) "target_type" "task"
        Yojson.Safe.Util.(item |> member "target_type" |> to_string);
      Alcotest.(check string) "target_id" task_id
        Yojson.Safe.Util.(item |> member "target_id" |> to_string);
      Alcotest.(check string) "severity" "bad"
        Yojson.Safe.Util.(item |> member "severity" |> to_string);
      Alcotest.(check bool) "summary mentions submit" true
        (Astring.String.is_infix
           ~affix:"검증 제출 필요"
           Yojson.Safe.Util.(item |> member "summary" |> to_string));
      Alcotest.(check bool) "friction includes review gap" true
        (List.mem
           (`String "evidence/review_warning.json")
           Yojson.Safe.Util.
             (item |> member "friction" |> member "cdal"
              |> member "review_gap_artifacts" |> to_list)))

let test_review_resolve_hides_matching_item () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "dashboard"));
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
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "dashboard"));
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
