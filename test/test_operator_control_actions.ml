module Types = Masc_domain

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
     Coord.transition_task_r config ~agent_name ~task_id ~action:Masc_domain.Claim ()
   with
  | Ok _ -> ()
  | Error err -> Alcotest.fail (Masc_domain.show_masc_error err));
  match
    Coord.transition_task_r config ~agent_name ~task_id ~action:Masc_domain.Start ()
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

(* review_queue / deferred_queue / review_summary fields were emitted for
   a retired dashboard surface; the producers (split_review_items,
   *_review_item) were also removed. Review decisions still reach the UI
   via [recent_reviews]. *)
