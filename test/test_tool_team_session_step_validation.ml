open Masc_mcp
open Test_tool_team_session_support

let test_missing_required_args () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let ok1, _ = dispatch_exn ctx ~name:"masc_team_session_start" ~args:(`Assoc []) in
  let ok2, _ = dispatch_exn ctx ~name:"masc_team_session_status" ~args:(`Assoc []) in
  let ok3, _ = dispatch_exn ctx ~name:"masc_team_session_stop" ~args:(`Assoc []) in
  let ok4, _ = dispatch_exn ctx ~name:"masc_team_session_report" ~args:(`Assoc []) in
  let ok5, _ =
    dispatch_exn ctx ~name:"masc_team_session_status"
      ~args:(`Assoc [ ("session_id", `String "../escape") ])
  in
  let ok6, _ =
    dispatch_exn ctx ~name:"masc_team_session_stop"
      ~args:(`Assoc [ ("session_id", `String "../../etc/passwd") ])
  in
  let ok7, _ =
    dispatch_exn ctx ~name:"masc_team_session_report"
      ~args:(`Assoc [ ("session_id", `String "bad-id") ])
  in
  let ok8, _ =
    dispatch_exn ctx ~name:"masc_team_session_compare"
      ~args:(`Assoc [ ("base_session_id", `String "bad-id") ])
  in
  let ok9, _ =
    dispatch_exn ctx ~name:"masc_team_session_list"
      ~args:(`Assoc [ ("status", `String "not-a-status") ])
  in
  let ok10, _ =
    dispatch_exn ctx ~name:"masc_team_session_step" ~args:(`Assoc [])
  in
  let ok11, _ =
    dispatch_exn ctx ~name:"masc_team_session_events" ~args:(`Assoc [])
  in
  let ok12, _ =
    dispatch_exn ctx ~name:"masc_team_session_prove" ~args:(`Assoc [])
  in
  let ok13, _ =
    dispatch_exn ctx ~name:"masc_team_session_step" ~args:(`Assoc [])
  in
  let ok14, _ =
    dispatch_exn ctx ~name:"masc_team_session_finalize" ~args:(`Assoc [])
  in
  Alcotest.(check bool) "start invalid" false ok1;
  Alcotest.(check bool) "status invalid" false ok2;
  Alcotest.(check bool) "stop invalid" false ok3;
  Alcotest.(check bool) "report invalid" false ok4;
  Alcotest.(check bool) "status traversal invalid" false ok5;
  Alcotest.(check bool) "stop traversal invalid" false ok6;
  Alcotest.(check bool) "report format invalid" false ok7;
  Alcotest.(check bool) "compare invalid" false ok8;
  Alcotest.(check bool) "list invalid status" false ok9;
  Alcotest.(check bool) "turn invalid" false ok10;
  Alcotest.(check bool) "events invalid" false ok11;
  Alcotest.(check bool) "prove invalid" false ok12;
  Alcotest.(check bool) "step invalid" false ok13;
  Alcotest.(check bool) "finalize invalid" false ok14;
  cleanup_dir base_dir

let test_step_actor_must_match_caller () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let session_id =
    start_session_exn ctx ~goal:"step-actor-must-match-caller" |> get_session_id
  in
  let ok, body =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("turn_kind", `String "note");
            ("actor", `String "planner");
            ("message", `String "spoofed note");
          ])
  in
  Alcotest.(check bool) "step rejects actor mismatch" false ok;
  let json = parse_json_exn body in
  Alcotest.(check string) "status error" "error"
    (json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  Alcotest.(check string) "actor mismatch message"
    "actor must match the authenticated caller; omit actor to use the current agent"
    (json |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string);
  cleanup_dir base_dir

let test_step_updates_delivery_contract_and_status_exposes_it () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let session_id =
    start_session_exn ctx ~goal:"contract-aware delivery loop"
    |> get_session_id
  in
  let step_ok, step_body =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("turn_kind", `String "note");
            ("message", `String "planner contract seeded");
            ( "delivery_contract",
              `Assoc
                [
                  ("contract_id", `String "contract-demo");
                  ("summary", `String "Ship the change with proof");
                  ( "acceptance_checks",
                    `List
                      [
                        `String "report mentions the new contract";
                        `String "proof exposes evaluator verdict";
                      ] );
                  ( "required_artifacts",
                    `List [ `String "report.json"; `String "proof.json" ] );
                  ("repair_budget", `Int 2);
                  ( "generator_roles",
                    `List [ `String "planner"; `String "implementer-a" ] );
                  ("evaluator_role", `String "reviewer");
                  ("evaluator_cascade", `String "cross_verifier");
                  ("evidence_refs", `List [ `String "session:contract-demo" ]);
                ] );
          ])
  in
  Alcotest.(check bool) "step ok" true step_ok;
  let step_json = parse_json_exn step_body |> result_field in
  Alcotest.(check string) "step response contract id" "contract-demo"
    Yojson.Safe.Util.(step_json |> member "delivery_contract" |> member "contract_id" |> to_string);
  Alcotest.(check bool) "step response verdict initially null" true
    Yojson.Safe.Util.(step_json |> member "latest_delivery_verdict" = `Null);
  let stored_session =
    Team_session_store.load_session config session_id |> Option.get
  in
  let contract =
    match stored_session.Team_session_types.delivery_contract with
    | Some contract -> contract
    | None -> Alcotest.fail "delivery contract was not persisted"
  in
  Alcotest.(check string) "contract id" "contract-demo" contract.contract_id;
  Alcotest.(check int) "repair budget" 2 contract.repair_budget;
  Alcotest.(check string) "evaluator cascade" "cross_verifier"
    contract.evaluator_cascade;
  let status_ok, status_body =
    dispatch_exn ctx ~name:"masc_team_session_status"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "status ok" true status_ok;
  let status_json = parse_json_exn status_body |> result_field in
  let status_contract =
    status_json |> Yojson.Safe.Util.member "delivery_contract"
  in
  Alcotest.(check string) "status contract id" "contract-demo"
    Yojson.Safe.Util.(status_contract |> member "contract_id" |> to_string);
  cleanup_dir base_dir

let test_step_spawn_requires_proc_mgr () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let session_id = start_session_exn ctx ~goal:"step-spawn-proc-manager-check" |> get_session_id in
  let step_ok, _ =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("spawn_prompt", `String "hello");
          ])
  in
  Alcotest.(check bool) "step should fail without proc_mgr for spawn" false step_ok;
  let events_ok, events_body =
    dispatch_exn ctx ~name:"masc_team_session_events"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("event_types", `List [ `String "team_step_spawn" ]);
          ])
  in
  Alcotest.(check bool) "events query ok" true events_ok;
  let events = events_list_of_body events_body in
  Alcotest.(check int) "spawn failure event recorded" 1 (List.length events);
  let first = List.hd events in
  let detail = Yojson.Safe.Util.member "detail" first in
  let success = detail |> Yojson.Safe.Util.member "success" |> Yojson.Safe.Util.to_bool in
  Alcotest.(check bool) "spawn failure success=false" false success;
  let error_msg =
    detail |> Yojson.Safe.Util.member "error" |> Yojson.Safe.Util.to_string_option
    |> Option.value ~default:""
  in
  Alcotest.(check bool) "spawn failure has error" true (String.trim error_msg <> "");
  ignore
    (dispatch_exn ctx ~name:"masc_team_session_stop"
       ~args:
         (`Assoc
           [
             ("session_id", `String session_id);
             ("reason", `String "cleanup");
             ("generate_report", `Bool false);
           ]));
  ignore (wait_until_terminal ctx session_id);
  cleanup_dir base_dir

let test_step_spawn_default_local_allows_worker_size_without_spawn_model () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let selection_note =
    "[model-selection] leader selected qwen3.5-35b-a3b-ud-q8-xl from inventory"
  in
  let session_id = start_session_exn ctx ~goal:"step-spawn-llama-model-check" |> get_session_id in
  let step_ok, step_body =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("spawn_prompt", `String "normalize evidence into strict JSON schema");
            ("spawn_role", `String "normalizer");
            ("worker_class", `String "executor");
            ("worker_size", `String "lg");
            ("spawn_selection_note", `String selection_note);
          ])
  in
  Alcotest.(check bool) "step fails later because proc_mgr is missing" false step_ok;
  let body = parse_json_exn step_body in
  let message =
    body |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check bool) "error mentions proc manager" true
    (try
       let _ =
         Str.search_forward
           (Str.regexp_string "process manager unavailable")
           message 0
       in
       true
     with Not_found -> false);
  let events_ok, events_body =
    dispatch_exn ctx ~name:"masc_team_session_events"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("event_types", `List [ `String "team_step_spawn" ]);
          ])
  in
  Alcotest.(check bool) "events query ok" true events_ok;
  let events = events_list_of_body events_body in
  Alcotest.(check int) "spawn event recorded" 1 (List.length events);
  let detail = Yojson.Safe.Util.member "detail" (List.hd events) in
  let worker_backend =
    detail |> Yojson.Safe.Util.member "worker_backend"
    |> Yojson.Safe.Util.to_string_option
  in
  Alcotest.(check (option string)) "worker backend" (Some "local")
    worker_backend;
  let worker_size =
    detail |> Yojson.Safe.Util.member "worker_size"
    |> Yojson.Safe.Util.to_string_option
  in
  Alcotest.(check (option string)) "worker size in event" (Some "lg")
    worker_size;
  let attached_events =
    Team_session_store.read_events config session_id
    |> List.filter (fun json ->
           Yojson.Safe.Util.member "event_type" json
           = `String "session_agent_attached")
  in
  Alcotest.(check int) "no phantom attachment before execution" 0
    (List.length attached_events);
  let session =
    Team_session_store.load_session config session_id |> Option.get
  in
  Alcotest.(check int) "planned worker recorded" 1
    (List.length session.planned_workers);
  let worker = List.hd session.planned_workers in
  Alcotest.(check string) "spawn agent normalized" "default"
    worker.Team_session_types.spawn_agent;
  Alcotest.(check (option string)) "single worker defaults to write scope"
    (Some "limited_code_change")
    (Option.map Team_session_types.execution_scope_to_string
       worker.execution_scope);
  Alcotest.(check (option string)) "tier falls back when middle model is unavailable"
    (Some "35b")
    (Option.map Team_session_types.model_tier_to_string worker.model_tier);
  let recorded_selection_note =
    detail |> Yojson.Safe.Util.member "spawn_selection_note"
    |> Yojson.Safe.Util.to_string_option
  in
  let recorded_selection_note =
    match recorded_selection_note with
    | Some value -> value
    | None -> Alcotest.fail "selection note missing in failure event"
  in
  Alcotest.(check bool) "selection note preserved in failure event" true
    (try
       let _ =
         Str.search_forward (Str.regexp_string selection_note)
           recorded_selection_note 0
       in
       true
     with Not_found -> false);
  Alcotest.(check bool) "routing summary appended in failure event" true
    (try
       let _ =
         Str.search_forward (Str.regexp_string "[routing]")
           recorded_selection_note 0
       in
       true
     with Not_found -> false);
  cleanup_dir base_dir

let test_step_rejects_legacy_spawn_fields () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let session_id =
    start_session_exn ctx ~goal:"step-rejects-legacy-spawn-fields"
    |> get_session_id
  in
  let ok, body =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("spawn_agent", `String "llama");
            ("spawn_prompt", `String "normalize evidence into strict JSON schema");
          ])
  in
  Alcotest.(check bool) "legacy spawn field rejected" false ok;
  let json = parse_json_exn body in
  Alcotest.(check string) "legacy spawn error"
    "spawn_agent is no longer supported in masc_team_session_step; use spawn_prompt, spawn_role, worker_class, and worker_size"
    (json |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string);
  cleanup_dir base_dir

let test_step_spawn_batch_accepts_explicit_spawn_model () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let session_id =
    start_session_exn ctx ~goal:"step-batch-accepts-explicit-spawn-model"
    |> get_session_id
  in
  let step_ok, _ =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ( "spawn_batch",
              `List
                [
                  `Assoc
                    [
                      ("spawn_model", `String "qwen3.5-35b-a3b-ud-q8-xl");
                      ("spawn_role", `String "planner");
                      ("spawn_prompt", `String "normalize evidence into strict JSON schema");
                    ];
                ] );
          ])
  in
  Alcotest.(check bool) "batch still fails later without proc manager" false
    step_ok;
  let session =
    Team_session_store.load_session config session_id |> Option.get
  in
  let planner =
    List.find
      (fun worker ->
        worker.Team_session_types.spawn_role = Some "planner")
      session.planned_workers
  in
  Alcotest.(check (option string)) "explicit spawn_model preserved"
    (Some "qwen3.5-35b-a3b-ud-q8-xl") planner.spawn_model;
  Alcotest.(check (option string)) "model tier inferred from explicit model"
    (Some "35b")
    (Option.map Team_session_types.model_tier_to_string planner.model_tier);
  cleanup_dir base_dir

let test_step_spawn_batch_defaults_execution_scope_by_worker_class () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let session_id =
    start_session_exn ctx ~goal:"step-batch-default-execution-scope"
    |> get_session_id
  in
  let step_ok, _ =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ( "spawn_batch",
              `List
                [
                  `Assoc
                    [
                      ("spawn_role", `String "planner");
                      ("worker_class", `String "manager");
                      ("spawn_prompt", `String "inspect and plan");
                    ];
                  `Assoc
                    [
                      ("spawn_role", `String "implementer");
                      ("worker_class", `String "executor");
                      ("spawn_prompt", `String "fix the failing test");
                    ];
                ] );
          ])
  in
  Alcotest.(check bool) "batch still fails later without proc manager" false step_ok;
  let session =
    Team_session_store.load_session config session_id |> Option.get
  in
  let planner =
    List.find
      (fun worker ->
        worker.Team_session_types.spawn_role = Some "planner")
      session.planned_workers
  in
  let implementer =
    List.find
      (fun worker ->
        worker.Team_session_types.spawn_role = Some "implementer")
      session.planned_workers
  in
  Alcotest.(check (option string)) "planner defaults readonly"
    (Some "observe_only")
    (Option.map Team_session_types.execution_scope_to_string
       planner.execution_scope);
  Alcotest.(check (option string)) "implementer defaults write"
    (Some "limited_code_change")
    (Option.map Team_session_types.execution_scope_to_string
       implementer.execution_scope);
  cleanup_dir base_dir

let test_step_delegate_requires_target_agent () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let session_id =
    start_session_exn ctx ~goal:"step-delegate-requires-target-agent"
    |> get_session_id
  in
  let ok, body =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("delegate_prompt", `String "continue from previous work");
          ])
  in
  Alcotest.(check bool) "delegate without target fails" false ok;
  let json = parse_json_exn body in
  Alcotest.(check string) "delegate target message"
    "target_agent is required when delegate_prompt is provided"
    (json |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string);
  cleanup_dir base_dir

let test_step_delegate_unknown_worker_rejected () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let session_id =
    start_session_exn ctx ~goal:"step-delegate-unknown-worker"
    |> get_session_id
  in
  let ok, body =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("target_agent", `String "llama-local-missing");
            ("delegate_prompt", `String "continue from previous work");
          ])
  in
  Alcotest.(check bool) "delegate unknown worker fails" false ok;
  let json = parse_json_exn body in
  Alcotest.(check string) "delegate unknown worker message"
    "target_agent did not match a known worker container"
    (json |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string);
  cleanup_dir base_dir
