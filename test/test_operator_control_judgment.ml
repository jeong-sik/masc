open Masc_mcp
open Test_operator_control_support

let test_digest_room_prefers_fresh_operator_judgment () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      ignore (Room.join config ~agent_name:"operator" ~capabilities:[] ());
      record_operator_judgment config ~surface:"command.namespace"
        ~target_type:Operator_judgment.Room ~target_id:None
        ~summary:"Pause the namespace before taking any destructive action."
        ~recommended_action:
          (`Assoc
            [
              ("action_kind", `String "pause_room");
              ("resolved_tool", `String "masc_operator_confirm");
              ("target_type", `String "namespace");
              ("target_id", `Null);
              ("reason", `String "operator judge requires manual gate");
              ("payload_preview", `Assoc [ ("reason", `String "manual review") ]);
            ])
        ~fresh_for_sec:90.0 ();
      Alcotest.(check int) "stored judgments" 1
        (List.length (Operator_judgment.load_all config));
      (match
         Operator_judgment.latest_active config ~surface:"command.namespace"
           ~target_type:Operator_judgment.Room ~target_id:None
       with
      | Some _ -> ()
      | None ->
          Alcotest.failf "expected room judgment in %s"
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

let test_digest_room_ignores_stale_operator_judgment () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      ignore (Room.join config ~agent_name:"operator" ~capabilities:[] ());
      record_operator_judgment config ~surface:"command.namespace"
        ~target_type:Operator_judgment.Room ~target_id:None
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

let test_digest_team_session_prefers_fresh_operator_judgment () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let ctx = team_ctx env sw config "operator" in
      let session_id = start_session_exn ctx in
      record_operator_judgment config ~surface:"command.swarm"
        ~target_type:Operator_judgment.Team_session ~target_id:(Some session_id)
        ~summary:"Spawn one more worker before continuing the session."
        ~fresh_for_sec:120.0 ();
      (match
         Operator_judgment.latest_active config ~surface:"command.swarm"
           ~target_type:Operator_judgment.Team_session
           ~target_id:(Some session_id)
       with
      | Some _ -> ()
      | None ->
          Alcotest.failf "expected team session judgment in %s"
            (Operator_judgment.judgments_path config));
      let digest =
        match
          Operator_control.digest_json ~actor:"operator"
            ~target_type:"team_session" ~target_id:session_id
            (operator_ctx env sw config "operator")
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "team_session judgment owner"
        "operator_keeper"
        Yojson.Safe.Util.(digest |> member "judgment_owner" |> to_string);
      Alcotest.(check string) "team_session active guidance layer" "judgment"
        Yojson.Safe.Util.(digest |> member "active_guidance_layer" |> to_string);
      Alcotest.(check string) "team_session active summary"
        "Spawn one more worker before continuing the session."
        Yojson.Safe.Util.
          (digest |> member "active_summary" |> member "summary" |> to_string))

let test_parse_session_judgment_ignores_null_recommended_action () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let session_id = start_session_exn (team_ctx env sw config "operator") in
      let judgment =
        Dashboard_operator_judge.parse_session_judgment
          ~config
          ~generated_at:(Types.now_iso ())
          ~generated_at_unix:(Unix.gettimeofday ())
          ~model_used:"glm:test"
          (`Assoc
            [
              ("session_id", `String session_id);
              ("summary", `String "Keep going.");
              ("confidence", `Float 0.82);
              ("recommended_action", `Null);
            ])
      in
      let stored =
        match
          Operator_judgment.latest_active config ~surface:"command.swarm"
            ~target_type:Operator_judgment.Team_session
            ~target_id:(Some session_id)
        with
        | Some value -> value
        | None -> Alcotest.fail "expected session judgment to be recorded"
      in
      Alcotest.(check bool) "judgment recorded" true (Option.is_some judgment);
      Alcotest.(check bool) "recommended action omitted" true
        (Option.is_none stored.Operator_judgment.recommended_action))

let test_operator_judgment_write_and_latest_roundtrip () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator-judge"));
      let ctx = operator_ctx env sw config "operator-judge" in
      let written =
        match
          Operator_control.judgment_write_json ctx
            (`Assoc
              [
                ("surface", `String "command.namespace");
                ("target_type", `String "namespace");
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
            (`Assoc [ ("surface", `String "command.namespace"); ("target_type", `String "namespace") ])
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "latest ok" "ok"
        Yojson.Safe.Util.(latest |> member "status" |> to_string);
      Alcotest.(check string) "latest summary"
        "Operator judge requests a human checkpoint."
        Yojson.Safe.Util.(latest |> member "judgment" |> member "summary" |> to_string))

let test_confirm_keeps_pending_token_when_delegated_action_fails () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let pending_dir = Filename.concat (Room.masc_dir config) "operator" in
      let path = Filename.concat pending_dir "pending_confirms.json" in
      Room_utils.mkdir_p pending_dir;
      let token = "retry-token" in
      let entry_json =
        `Assoc
          [
            ("token", `String token);
            ("trace_id", `String "trace-retry");
            ("actor", `String "operator");
            ("action_type", `String "team_stop");
            ("target_type", `String "team_session");
            ("target_id", `String "missing-session");
            ("payload", `Assoc []);
            ("delegated_tool", `String "masc_team_session_stop");
            ("created_at", `String (Types.now_iso ()));
            ("expires_at", `Null);
          ]
      in
      Room_utils.write_json config path (`List [ entry_json ]);
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
      Alcotest.(check int) "pending confirm retained" 1 (List.length pending_confirms);
      Alcotest.(check string) "same token retained" token
        Yojson.Safe.Util.(List.hd pending_confirms |> member "token" |> to_string))

let test_digest_recommends_worker_spawn_batch_for_planned_worker_without_turn () =
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
      let now = Unix.gettimeofday () in
      let update_result =
        Team_session_store.update_session config session_id (fun session ->
            {
              session with
              started_at = now -. 240.0;
              planned_workers =
                [
                  {
                    Team_session_types.spawn_agent = "llama";
                    runtime_actor = Some "llama-local-deadbeef";
                    spawn_role = Some "implementer-a";
                    runtime_binding_ref = None;
                    spawn_model = Some "qwen3.5";
                    execution_scope = Some Team_session_types.Limited_code_change;
                    worker_class = None;
                    parent_actor = None;
                    capsule_mode = None;
                    runtime_pool = None;
                    lane_id = Some "lane-a";
                    controller_level = Some Team_session_types.Controller_worker;
                    control_domain = Some Team_session_types.Domain_execution;
                    supervisor_actor = Some "ctrl-lane-a";
                    task_profile = Some Team_session_types.Profile_normalize;
                    risk_level = Some Team_session_types.Risk_low;
                    artifact_scope = [];
                    routing_confidence = Some 0.82;
                    routing_reason = Some "rule:machine_checkable";
                    thinking_enabled = None;
                    thinking_budget = None;
                    max_turns = None;
                    timeout_seconds = None;
                    routing_escalated = false;
                  };
                ];
              updated_at_iso = Types.now_iso ();
            })
      in
      (match update_result with Ok _ -> () | Error err -> Alcotest.fail err);
      let ctx = operator_ctx env sw config "dashboard" in
      let digest =
        match
          Operator_control.digest_json ~actor:"dashboard"
            ~target_type:"team_session" ~target_id:session_id ctx
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      let recommendations =
        Yojson.Safe.Util.(digest |> member "recommended_actions" |> to_list)
      in
      let recommendation =
        match
          List.find_opt
            (fun item ->
              Yojson.Safe.Util.(item |> member "action_type" |> to_string)
              = "team_worker_spawn_batch")
            recommendations
        with
        | Some item -> item
        | None -> Alcotest.fail "expected team_worker_spawn_batch recommendation"
      in
      let spawn_batch =
        Yojson.Safe.Util.
          (recommendation |> member "suggested_payload" |> member "spawn_batch"
         |> to_list)
      in
      Alcotest.(check int) "single worker stub" 1 (List.length spawn_batch);
      let worker = List.hd spawn_batch in
      Alcotest.(check string) "spawn_role" "implementer-a"
        Yojson.Safe.Util.(worker |> member "spawn_role" |> to_string);
      Alcotest.(check string) "recommendation provenance" "fallback"
        Yojson.Safe.Util.(recommendation |> member "provenance" |> to_string))
