module Types = Masc_domain

open Masc
open Test_operator_control_support

let test_digest_workspace_prefers_fresh_operator_judgment () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      ignore (Workspace.bind_session config ~agent_name:"operator" ~capabilities:[] ());
      record_operator_judgment config ~surface:"command.namespace"
        ~target_type:Operator_judgment.Workspace ~target_id:None
        ~summary:"Pause the namespace before taking any destructive action."
        ~recommended_action:
          (`Assoc
            [
              ("action_kind", `String "pause_workspace");
              ("resolved_tool", `String "masc_operator_confirm");
              ( "target_type"
              , `String Operator_action_constants.workspace_target_type );
              ("target_id", `Null);
              ("reason", `String "operator judge requires manual gate");
              ("payload_preview", `Assoc [ ("reason", `String "manual review") ]);
            ])
        ~fresh_for_sec:90.0 ();
      Alcotest.(check int) "stored judgments" 1
        (List.length (Operator_judgment.load_all config));
      (match
         Operator_judgment.latest_active config ~surface:"command.namespace"
           ~target_type:Operator_judgment.Workspace ~target_id:None
       with
      | Some _ -> ()
      | None ->
          Alcotest.failf "expected workspace judgment in %s"
            (Operator_judgment.judgments_path config));
      let ctx = operator_ctx env sw config "operator" in
      let digest =
        match Operator_control.digest_json ~actor:"operator" ctx with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "judgment owner" "operator_keeper"
        Yojson.Safe.Util.(digest |> member "judgment_owner" |> to_string);
      Alcotest.(check bool) "authoritative judgment available" true
        Yojson.Safe.Util.
          (digest |> member "authoritative_judgment_available" |> to_bool);
      Alcotest.(check string) "active guidance layer" "judgment"
        Yojson.Safe.Util.(digest |> member "active_guidance_layer" |> to_string);
      Alcotest.(check string) "active summary from judgment"
        "Pause the namespace before taking any destructive action."
        Yojson.Safe.Util.
          (digest |> member "active_summary" |> member "summary" |> to_string);
      Alcotest.(check string) "active recommendation source" "judgment"
        Yojson.Safe.Util.(digest |> member "active_recommendation_source" |> to_string);
      Alcotest.(check bool) "judgment present" true
        (Yojson.Safe.Util.member "judgment" digest <> `Null))

let test_digest_workspace_ignores_stale_operator_judgment () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      ignore (Workspace.bind_session config ~agent_name:"operator" ~capabilities:[] ());
      record_operator_judgment config ~surface:"command.namespace"
        ~target_type:Operator_judgment.Workspace ~target_id:None
        ~summary:"This judgment is stale." ~fresh_for_sec:(-5.0) ();
      let ctx = operator_ctx env sw config "operator" in
      let digest =
        match Operator_control.digest_json ~actor:"operator" ctx with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "judgment owner fallback" "fallback_read_model"
        Yojson.Safe.Util.(digest |> member "judgment_owner" |> to_string);
      Alcotest.(check bool) "authoritative judgment unavailable" false
        Yojson.Safe.Util.
          (digest |> member "authoritative_judgment_available" |> to_bool);
      Alcotest.(check string) "active guidance layer fallback" "fallback"
        Yojson.Safe.Util.(digest |> member "active_guidance_layer" |> to_string);
      Alcotest.(check bool) "judgment missing" true
        (Yojson.Safe.Util.member "judgment" digest = `Null))

let test_guidance_ignores_unsupported_target_type () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      record_operator_judgment config ~surface:"command.namespace"
        ~target_type:Operator_judgment.Workspace ~target_id:None
        ~summary:"Root guidance must not leak to keeper targets."
        ~fresh_for_sec:90.0 ();
      let fields =
        Operator_digest_guidance.active_guidance_fields ~config ~actor:"operator"
          ~target_type:"keeper" ~target_id:None ~fallback_recommendations:[]
          ~fallback_summary:(`Assoc [ ("count", `Int 0) ])
      in
      let guidance = `Assoc fields in
      Alcotest.(check string) "judgment owner fallback" "fallback_read_model"
        Yojson.Safe.Util.(guidance |> member "judgment_owner" |> to_string);
      Alcotest.(check bool) "authoritative judgment unavailable" false
        Yojson.Safe.Util.
          (guidance |> member "authoritative_judgment_available" |> to_bool);
      Alcotest.(check string) "active guidance layer fallback" "fallback"
        Yojson.Safe.Util.(guidance |> member "active_guidance_layer" |> to_string);
      Alcotest.(check bool) "judgment missing" true
        (Yojson.Safe.Util.member "judgment" guidance = `Null))

let test_operator_judgment_write_and_latest_roundtrip () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator-judge"));
      let ctx = operator_ctx env sw config "operator-judge" in
      let written =
        match
          Operator_control.judgment_write_json ctx
            (`Assoc
              [
                ("surface", `String "command.namespace");
                ("target_type", `String "workspace");
                ("summary", `String "Operator judge requests a human checkpoint.");
                ("confidence", `Float 0.88);
                ("fresh_ttl_sec", `Int 90);
                ("evidence_refs", `List [ `String "trace:opsd-1" ]);
              ])
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "write ok" "ok"
        Yojson.Safe.Util.(written |> member "status" |> to_string);
      let latest =
        match
          Operator_control.judgment_latest_json ctx
            (`Assoc
              [ ("surface", `String "command.namespace"); ("target_type", `String "workspace") ])
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "latest ok" "ok"
        Yojson.Safe.Util.(latest |> member "status" |> to_string);
      Alcotest.(check string) "latest summary"
        "Operator judge requests a human checkpoint."
        Yojson.Safe.Util.(latest |> member "judgment" |> member "summary" |> to_string))

let test_operator_judgment_rejects_retired_target_type_aliases () =
  Alcotest.(check bool)
    "namespace no longer parses"
    true
    (Option.is_none (Operator_judgment.target_type_of_string "namespace"));
  Alcotest.(check (result string string))
    "digest rejects namespace"
    (Error Operator_action_constants.workspace_target_type_error)
    (Operator_digest_types.normalize_digest_target_type (Some "namespace"));
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator-judge"));
      let ctx = operator_ctx env sw config "operator-judge" in
      match
        Operator_control.judgment_write_json ctx
          (`Assoc
            [
              ("surface", `String "command.namespace");
              ("target_type", `String "namespace");
              ("summary", `String "Retired alias must be rejected.");
            ])
      with
      | Ok _ -> Alcotest.fail "namespace target_type should be rejected"
      | Error err ->
          Alcotest.(check string)
            "write rejects namespace"
            Operator_action_constants.workspace_target_type_error err)

let test_confirm_consumes_pending_token_before_delegated_action_fails () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let pending_dir = Filename.concat (Workspace.masc_dir config) "operator" in
      let path = Filename.concat pending_dir "pending_confirms.json" in
      Workspace_utils.mkdir_p pending_dir;
      let token = "retry-token" in
      let entry_json =
        `Assoc
          [
            ("token", `String token);
            ("trace_id", `String "trace-retry");
            ("actor", `String "operator");
            ("action_type", `String "missing_action_type");
            ( "target_type"
            , `String Operator_action_constants.workspace_target_type );
            ("target_id", `Null);
            ("payload", `Assoc []);
            ("delegated_tool", `String "missing_operator_tool");
            ("created_at", `String (Masc_domain.now_iso ()));
            ("expires_at", `Null);
          ]
      in
      (match Workspace_utils.write_json_result config path (`List [ entry_json ]) with
       | Ok () -> ()
       | Error err -> Alcotest.failf "failed to persist pending confirm fixture: %s" err);
      let initial_pending_confirms =
        Operator_control.pending_confirms_json ~actor:"operator" config
        |> Yojson.Safe.Util.to_list
      in
      Alcotest.(check int)
        "pending confirm fixture persisted" 1
        (List.length initial_pending_confirms);
      let ctx = operator_ctx env sw config "operator" in
      (match
         Operator_control.confirm_json ctx
           (`Assoc [ ("actor", `String "operator"); ("confirm_token", `String token) ])
       with
      | Ok _ -> Alcotest.fail "expected delegated action failure"
      | Error err ->
          Alcotest.(check bool) "non-empty error" true (String.length err > 0));
      let pending_confirms =
        Operator_control.pending_confirms_json ~actor:"operator" config
        |> Yojson.Safe.Util.to_list
      in
      Alcotest.(check int) "pending confirm consumed" 0 (List.length pending_confirms))

(* test_digest_recommends_worker_spawn_batch_for_planned_worker_without_turn
   removed: depended on team session start/update which is no longer available. *)

let tests =
  [
    Alcotest.test_case "digest prefers fresh operator judgment" `Quick
      test_digest_workspace_prefers_fresh_operator_judgment;
    Alcotest.test_case "digest ignores stale operator judgment" `Quick
      test_digest_workspace_ignores_stale_operator_judgment;
    Alcotest.test_case "guidance ignores unsupported target type" `Quick
      test_guidance_ignores_unsupported_target_type;
    Alcotest.test_case "operator judgment write/latest roundtrip" `Quick
      test_operator_judgment_write_and_latest_roundtrip;
    Alcotest.test_case "rejects retired target type aliases" `Quick
      test_operator_judgment_rejects_retired_target_type_aliases;
    Alcotest.test_case "confirm consumes token before delegated action failure" `Quick
      test_confirm_consumes_pending_token_before_delegated_action_fails;
  ]

let () = Alcotest.run "operator_control_judgment" [ ("operator_control_judgment", tests) ]
