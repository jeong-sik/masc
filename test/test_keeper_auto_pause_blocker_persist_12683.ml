(** #12683 — pin that auto-pause paths write structured [last_blocker]
    into keeper_meta so the blocker survives
    supervisor unregister/restart.

    Structural fact this test pins: a meta JSON written with
    structured [last_blocker] round-trips through
    serialization/deserialization without loss, so the blocker survives
    server restart.

    (Legacy ["oas_timeout_budget"] wire mapping was retired by #17805;
    related test rows have been removed accordingly.) *)

open Alcotest
module KT = Keeper_types
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_meta_json_parse = Masc.Keeper_meta_json_parse
module Keeper_meta_json = Masc.Keeper_meta_json
module Keeper_meta_store = Masc.Keeper_meta_store
module MC = Masc.Keeper_meta_contract

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.is_directory path
    then (
      Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path
  in
  try rm dir with _ -> ()

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" || Sys.file_exists path then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)

let write_file path content =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
    output_string oc content)

let runtime_toml_with_pause_threshold threshold =
  Printf.sprintf
    {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1

[pause]
turn_fail_streak_threshold = %d
|}
    threshold

let with_runtime_config content f =
  let config_dir = temp_dir "masc-runtime-pause-config-" in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let prior = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      (match prior with
       | Some value -> Unix.putenv "MASC_CONFIG_DIR" value
       | None -> Unix.putenv "MASC_CONFIG_DIR" "");
      Config_dir_resolver.reset ();
      cleanup_dir config_dir)
    (fun () ->
       let runtime_config_path =
         Filename.concat config_dir Config_dir_resolver.runtime_toml_filename
       in
       write_file runtime_config_path content;
       Unix.putenv "MASC_CONFIG_DIR" config_dir;
       Config_dir_resolver.reset ();
       (match Runtime.init_default ~config_path:runtime_config_path with
        | Ok () -> ()
       | Error err -> fail ("runtime init: " ^ err));
       f ())

let prompt_metrics =
  Masc.Keeper_agent_prompt_metrics.build_prompt_metrics ~system_prompt:""
    ~dynamic_context:"" ~user_message:""

let ctx_composition : Masc.Keeper_agent_prompt_metrics.ctx_composition_metrics =
  { actual_input_tokens = None
  ; display_total_tokens = 0
  ; estimated_known_tokens = 0
  ; segments = []
  }

let tool_surface : Masc.Keeper_agent_tool_surface.tool_surface_metrics =
  { turn_lane = Masc.Keeper_agent_tool_surface.Lane_tool_optional
  ; config_root = ""
  ; runtime_config_path = None
  }

let tool_call
      ?typed_outcome
      ?(input_fingerprint = Some "input")
      ?(output_fingerprint = Some "output")
      tool_name
  : Masc.Keeper_agent_result.tool_call_detail
  =
  { tool_name
  ; provider = "test"
  ; outcome = "ok"
  ; typed_outcome
  ; latency_ms = 0.0
  ; task_id = None
  ; route_evidence = None
  ; input_fingerprint
  ; output_fingerprint
  }

let healthy_operator_disposition
  : Masc.Keeper_agent_result.operator_disposition
  =
  { disposition = Masc.Keeper_execution_receipt.Disp_pass
  ; reason = Masc.Keeper_execution_receipt.Reason_healthy
  }

let pause_operator_disposition
  : Masc.Keeper_agent_result.operator_disposition
  =
  { disposition = Masc.Keeper_execution_receipt.Disp_pause_human
  ; reason = Masc.Keeper_execution_receipt.Reason_completion_contract_unsatisfied
  }

let non_healthy_pass_operator_disposition
  : Masc.Keeper_agent_result.operator_disposition
  =
  { disposition = Masc.Keeper_execution_receipt.Disp_pass
  ; reason = Masc.Keeper_execution_receipt.Reason_turn_budget_exhausted
  }

let pass_next_model_operator_disposition
  : Masc.Keeper_agent_result.operator_disposition
  =
  { disposition = Masc.Keeper_execution_receipt.Disp_pass_next_model
  ; reason = Masc.Keeper_execution_receipt.Reason_runtime_fallback
  }

let run_result
      ?(response_text = "direct reply")
      ?(stop_reason = Runtime_agent.Completed)
      ?(operator_disposition = Some healthy_operator_disposition)
      ?(tool_calls = [])
      ()
  : Masc.Keeper_agent_run.run_result
  =
  { response_text
  ; model_used = "test-model"
  ; prompt_metrics
  ; ctx_composition
  ; runtime_observation = None
  ; turn_count = 1
  ; usage = Masc.Inference_utils.zero_usage
  ; usage_reported = true
  ; tool_calls
  ; completion_contract_result =
      Masc.Keeper_execution_receipt.Contract_satisfied_execution
  ; operator_disposition
  ; checkpoint = None
  ; trace_ref = None
  ; run_validation = None
  ; stop_reason
  ; inference_telemetry = None
  ; tool_surface
  ; pre_dispatch_compacted = false
  ; pre_dispatch_compaction_trigger = None
  ; pre_dispatch_compaction_before_tokens = None
  ; pre_dispatch_compaction_after_tokens = None
  }

let test_turn_timeout_blocker_class_roundtrip () =
  let cls = Keeper_meta_contract.Turn_timeout in
  let label = Keeper_meta_contract.blocker_class_to_string cls in
  check bool "label non-empty" true (String.length label > 0);
  match MC.blocker_class_of_serialized_string label with
  | Some _ -> ()
  | None -> fail "Turn_timeout label did not parse back"

let test_stale_fleet_batch_blocker_class_roundtrip () =
  let cls = Keeper_meta_contract.Stale_fleet_batch in
  let label = Keeper_meta_contract.blocker_class_to_string cls in
  check string "label" "stale_fleet_batch" label;
  match MC.blocker_class_of_serialized_string label with
  | Some MC.Stale_fleet_batch -> ()
  | Some _ -> fail "Stale_fleet_batch label parsed as wrong class"
  | None -> fail "Stale_fleet_batch label did not parse back"

let test_capacity_backpressure_blocker_class_roundtrip () =
  let cls = Keeper_meta_contract.Capacity_backpressure in
  let label = Keeper_meta_contract.blocker_class_to_string cls in
  check string "label" "capacity_backpressure" label;
  match MC.blocker_class_of_serialized_string label with
  | Some MC.Capacity_backpressure -> ()
  | Some _ -> fail "Capacity_backpressure label parsed as wrong class"
  | None -> fail "Capacity_backpressure label did not parse back"

let test_meta_json_roundtrip_with_auto_pause_blocker () =
  let base_json = `Assoc [
    ("name", `String "test-keeper");
    ("agent_name", `String "agent-test");
    ("trace_id", `String "trace-test");
    ("tool_access", `List []);
  ] in
  let meta = match Keeper_meta_json_parse.meta_of_json base_json with
    | Ok m -> m
    | Error err -> fail ("parse base: " ^ err)
  in
  let blocker_text = "oas_timeout_budget" in
  let paused_meta = { meta with
    paused = true;
    auto_resume_after_sec = Some 3600.0;
    runtime = { meta.runtime with
      last_blocker =
        Some (Keeper_meta_contract.blocker_info_of_class
                ~detail:blocker_text Keeper_meta_contract.Turn_timeout);
    };
  } in
  let json = Keeper_meta_json.meta_to_json paused_meta in
  let reparsed = match Keeper_meta_json_parse.meta_of_json json with
    | Ok m -> m
    | Error err -> fail ("roundtrip: " ^ err)
  in
  check bool "paused" true reparsed.paused;
  check (option (float 0.1)) "auto_resume_after_sec"
    (Some 3600.0) reparsed.auto_resume_after_sec;
  (match reparsed.runtime.last_blocker with
   | Some info ->
     check string "last_blocker.detail preserved" blocker_text info.detail;
     (match info.klass with
      | Keeper_meta_contract.Turn_timeout -> ()
      | _ -> fail "legacy timeout-budget blocker did not collapse to Turn_timeout")
   | None -> fail "last_blocker should be Some after roundtrip")

let test_meta_json_roundtrip_with_stale_storm_blocker () =
  let base_json = `Assoc [
    ("name", `String "test-keeper2");
    ("agent_name", `String "agent-test2");
    ("trace_id", `String "trace-test2");
    ("tool_access", `List []);
  ] in
  let meta = match Keeper_meta_json_parse.meta_of_json base_json with
    | Ok m -> m
    | Error err -> fail ("parse base: " ^ err)
  in
  let blocker_text = Keeper_meta_contract.blocker_class_to_string Keeper_meta_contract.Turn_timeout in
  let paused_meta = { meta with
    paused = true;
    auto_resume_after_sec = Some 7200.0;
    runtime = { meta.runtime with
      last_blocker =
        Some (Keeper_meta_contract.blocker_info_of_class
                ~detail:blocker_text Keeper_meta_contract.Turn_timeout);
    };
  } in
  let json = Keeper_meta_json.meta_to_json paused_meta in
  let reparsed = match Keeper_meta_json_parse.meta_of_json json with
    | Ok m -> m
    | Error err -> fail ("roundtrip: " ^ err)
  in
  (match reparsed.runtime.last_blocker with
   | Some info ->
     check string "last_blocker.detail" blocker_text info.detail;
     (match info.klass with
      | Keeper_meta_contract.Turn_timeout -> ()
      | _ -> fail "blocker klass not Turn_timeout after roundtrip")
   | None -> fail "last_blocker should be Some after roundtrip")

let legacy_base_json name =
  `Assoc
    [
      "name", `String name;
      "agent_name", `String (name ^ "-agent");
      "trace_id", `String ("trace-" ^ name);
      "tool_access", `List [];
    ]

let make_meta name =
  match Keeper_meta_json_parse.meta_of_json (legacy_base_json name) with
  | Ok meta -> meta
  | Error err -> fail ("parse base: " ^ err)

let queue_contains_post_id queue post_id =
  queue
  |> Keeper_event_queue.to_list
  |> List.exists (fun stimulus ->
    String.equal stimulus.Keeper_event_queue.post_id post_id)

let task_id_of_created_task (created : Masc.Workspace.add_task_success) =
  match Keeper_id.Task_id.of_string created.task_id with
  | Ok task_id -> task_id
  | Error err -> fail err

let create_owned_active_task config meta =
  let created =
    match
      Masc.Workspace.add_task_with_result
        config
        ~title:"no-progress release regression"
        ~priority:1
        ~description:"owned active task must release when no-progress pause latches"
    with
    | Ok created -> created
    | Error err -> fail (Masc.Workspace.add_task_error_to_string err)
  in
  (match
     Masc.Workspace.claim_task_r
       config
       ~agent_name:meta.Keeper_meta_contract.agent_name
       ~task_id:created.task_id
       ()
   with
   | Ok _ -> ()
   | Error err -> fail (Masc_domain.masc_error_to_string err));
  (match
     Masc.Workspace.transition_task_r
       config
       ~agent_name:meta.Keeper_meta_contract.agent_name
       ~task_id:created.task_id
       ~action:Masc_domain.Start
       ()
   with
   | Ok _ -> ()
   | Error err -> fail (Masc_domain.masc_error_to_string err));
  created

let task_status_by_id config task_id =
  Masc.Workspace.get_tasks_raw config
  |> List.find (fun (task : Masc_domain.task) -> String.equal task.id task_id)
  |> fun task -> task.Masc_domain.task_status

let event_queue_snapshot_path ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
    "event-queue.json"

let test_no_progress_loop_detection_pauses_keeper () =
  let base_path = temp_dir "masc-no-progress-pause-" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "no-progress-paused" in
       let meta = make_meta keeper_name in
       Masc.Keeper_registry.clear ();
       ignore (Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       let paused_meta =
         Masc.Keeper_unified_turn_no_progress.mark_loop_detected
           ~config
           meta
           ~streak:10
           ~threshold:10
       in
       check bool "returned meta paused" true paused_meta.paused;
       check
         (option (float 0.001))
         "safety pause has no auto-resume"
         None
         paused_meta.auto_resume_after_sec;
       (match paused_meta.runtime.last_blocker with
        | Some { Keeper_meta_contract.klass = No_progress_loop; detail } ->
          check
            string
            "blocker detail"
            "no_progress loop detected: streak=10 threshold=10; auto-paused after repeated no-evidence turns; operator resume clears the no-progress latch"
            detail
        | Some _ -> fail "expected No_progress_loop blocker"
        | None -> fail "expected no_progress loop blocker");
       match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
       | Some entry ->
         check bool "registry meta paused" true entry.Masc.Keeper_registry.meta.paused;
         (match entry.Masc.Keeper_registry.last_failure_reason with
          | Some (Masc.Keeper_registry.Provider_runtime_error { code; _ }) ->
	            check
	              string
	              "registry no-progress failure code"
	              Masc.Keeper_unified_turn_no_progress.failure_reason_code
	              code
	          | Some _ -> fail "expected no_progress provider-runtime failure reason"
	          | None -> fail "expected no_progress failure reason");
	         check
	           bool
	           "no-progress pause does not queue synthetic recovery stimulus"
	           true
	           (Keeper_event_queue.is_empty
	              (Masc.Keeper_registry_event_queue.snapshot
	                 ~base_path:config.base_path
	                 keeper_name))
	       | None -> fail "expected registered keeper")

let test_no_progress_loop_detection_releases_owned_active_task () =
  let base_path = temp_dir "masc-no-progress-release-" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       let _init_msg = Masc.Workspace.init config ~agent_name:(Some "operator") in
       let keeper_name = "no-progress-owner" in
       let meta = make_meta keeper_name in
       let created = create_owned_active_task config meta in
       let current_task_id = task_id_of_created_task created in
       let meta = { meta with current_task_id = Some current_task_id } in
       Masc.Keeper_registry.clear ();
       (match Keeper_meta_store.write_meta config meta with
        | Ok () -> ()
        | Error err -> fail err);
       let _entry =
         Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta
       in
       let paused_meta =
         Masc.Keeper_unified_turn_no_progress.mark_loop_detected
           ~config
           meta
           ~streak:10
           ~threshold:10
       in
       check (option string) "returned meta current_task_id cleared" None
         (Option.map Keeper_id.Task_id.to_string paused_meta.current_task_id);
       (match task_status_by_id config created.task_id with
        | Masc_domain.Todo -> ()
        | status ->
          fail
            (Printf.sprintf
               "expected no-progress pause to release task to todo, got %s"
               (Masc_domain.task_status_to_string status)));
       match Keeper_meta_store.read_meta config keeper_name with
       | Ok (Some persisted) ->
         check bool "persisted meta paused" true persisted.paused;
         check (option string) "persisted current_task_id cleared" None
           (Option.map Keeper_id.Task_id.to_string persisted.current_task_id)
       | Ok None -> fail "expected persisted keeper meta"
       | Error err -> fail err)

let test_completion_contract_pause_sync_releases_owned_active_task () =
  let base_path = temp_dir "masc-completion-contract-release-" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       let _init_msg = Masc.Workspace.init config ~agent_name:(Some "operator") in
       let keeper_name = "completion-contract-owner" in
       let meta = make_meta keeper_name in
       let created = create_owned_active_task config meta in
       let current_task_id = task_id_of_created_task created in
       let blocker =
         Keeper_meta_contract.blocker_info_of_class
           ~detail:"completion contract violated"
           Keeper_meta_contract.Completion_contract_violation
       in
       let meta =
         { meta with
           current_task_id = Some current_task_id
         ; runtime = { meta.runtime with last_blocker = Some blocker }
         }
       in
       Masc.Keeper_registry.clear ();
       (match Keeper_meta_store.write_meta config meta with
        | Ok () -> ()
        | Error err -> fail err);
       ignore (Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       match
         Masc.Keeper_turn_runtime_budget.sync_keeper_paused_state_with_resume_policy
           ~config
           ~meta
           ~paused:true
           ~resume_policy:Masc.Keeper_supervisor_pause_policy.Manual_resume_required
       with
       | Error err -> fail err
       | Ok paused_meta ->
         check bool "returned meta paused" true paused_meta.paused;
         check (option string) "returned meta current_task_id cleared" None
           (Option.map Keeper_id.Task_id.to_string paused_meta.current_task_id);
         (match task_status_by_id config created.task_id with
          | Masc_domain.Todo -> ()
          | status ->
            fail
              (Printf.sprintf
                 "expected completion-contract pause to release task to todo, got %s"
                 (Masc_domain.task_status_to_string status)));
         (match Keeper_meta_store.read_meta config keeper_name with
          | Ok (Some persisted) ->
            check bool "persisted meta paused" true persisted.paused;
            check (option string) "persisted current_task_id cleared" None
              (Option.map Keeper_id.Task_id.to_string persisted.current_task_id);
            (match persisted.runtime.last_blocker with
             | Some
                 { Keeper_meta_contract.klass =
                     Keeper_meta_contract.Completion_contract_violation
                 ; _
                 } -> ()
             | Some _ -> fail "expected completion-contract blocker to remain"
             | None -> fail "expected completion-contract blocker to remain")
          | Ok None -> fail "expected persisted keeper meta"
          | Error err -> fail err))

let test_operator_resume_clears_no_progress_loop_latch () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "masc-no-progress-resume-" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_no_progress_loop_detector.reset_all_for_test ();
      cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "no-progress-resume" in
       let meta = make_meta keeper_name in
       Masc.Keeper_registry.clear ();
       ignore (Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       ignore
         (Masc.Keeper_no_progress_loop_detector.record_turn
            ~threshold_override:1
            ~keeper_name
            ~made_progress:false
            ());
       let paused_meta =
         Masc.Keeper_unified_turn_no_progress.mark_loop_detected
           ~config
           meta
           ~streak:10
           ~threshold:10
       in
       let recovery_post_id = "no-progress-loop:" ^ keeper_name in
       check bool
         "detector latched before resume"
         true
         (Masc.Keeper_no_progress_loop_detector.is_latched ~keeper_name);
       check bool
         "no recovery stimulus queued before resume"
         false
         (queue_contains_post_id
            (Masc.Keeper_registry_event_queue.snapshot
               ~base_path:config.base_path
               keeper_name)
            recovery_post_id);
       let pending_summary =
         Masc.Keeper_reaction_ledger.summary_for_keeper
           ~base_path:config.base_path
           ~keeper_name
           ~limit:10
       in
       check int
         "no ledger recovery stimulus pending before resume"
         0
         (pending_summary
          |> Yojson.Safe.Util.member "pending_no_progress_recovery_count"
          |> Yojson.Safe.Util.to_int);
       let resumed_meta =
         match
           Masc.Keeper_unified_turn_no_progress.clear_for_operator_resume
             ~base_path:config.base_path
             paused_meta
         with
         | Ok meta -> meta
         | Error err -> fail ("operator resume clear failed: " ^ err)
       in
       check bool
         "detector reset by operator resume"
         false
         (Masc.Keeper_no_progress_loop_detector.is_latched ~keeper_name);
       check bool
         "operator resume drops queued recovery stimulus"
         false
         (queue_contains_post_id
            (Masc.Keeper_registry_event_queue.snapshot
               ~base_path:config.base_path
               keeper_name)
            recovery_post_id);
       check bool
         "operator resume drops durable recovery stimulus"
         false
         (queue_contains_post_id
            (Keeper_event_queue_persistence.load
               ~base_path:config.base_path
               ~keeper_name)
            recovery_post_id);
       let resumed_summary =
         Masc.Keeper_reaction_ledger.summary_for_keeper
           ~base_path:config.base_path
           ~keeper_name
           ~limit:10
       in
       check int
         "operator resume closes pending recovery ledger stimulus"
         0
         (resumed_summary
          |> Yojson.Safe.Util.member "pending_no_progress_recovery_count"
          |> Yojson.Safe.Util.to_int);
       check int
         "operator resume has no recovery stimulus reaction"
         0
         (resumed_summary
          |> Yojson.Safe.Util.member "operator_escalation_count"
          |> Yojson.Safe.Util.to_int);
       (match resumed_meta.runtime.last_blocker with
        | None -> ()
        | Some _ -> fail "expected no_progress meta blocker to clear");
       match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
       | Some entry ->
         (match entry.Masc.Keeper_registry.last_failure_reason with
          | None -> ()
          | Some _ -> fail "expected no_progress failure reason to clear")
       | None -> fail "expected registered keeper")

let test_operator_resume_keeps_no_progress_state_on_drop_failure () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "masc-no-progress-resume-drop-fail-" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_no_progress_loop_detector.reset_all_for_test ();
      cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "no-progress-resume-drop-fail" in
       let meta = make_meta keeper_name in
       Masc.Keeper_registry.clear ();
       ignore (Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       ignore
         (Masc.Keeper_no_progress_loop_detector.record_turn
            ~threshold_override:1
            ~keeper_name
            ~made_progress:false
            ());
       let paused_meta =
         Masc.Keeper_unified_turn_no_progress.mark_loop_detected
           ~config
           meta
           ~streak:10
           ~threshold:10
       in
       let recovery_post_id = "no-progress-loop:" ^ keeper_name in
       check bool
         "detector latched before failed resume"
         true
         (Masc.Keeper_no_progress_loop_detector.is_latched ~keeper_name);
       check bool
         "no synthetic recovery stimulus before failed resume"
         false
         (queue_contains_post_id
            (Masc.Keeper_registry_event_queue.snapshot
               ~base_path:config.base_path
               keeper_name)
            recovery_post_id);
       let pending_path =
         event_queue_snapshot_path ~base_path:config.base_path ~keeper_name
       in
       mkdir_p (Filename.dirname pending_path);
       Unix.mkdir pending_path 0o755;
       (match
          Masc.Keeper_unified_turn_no_progress.clear_for_operator_resume
            ~base_path:config.base_path
            paused_meta
        with
        | Ok _ -> fail "expected operator resume clear to fail"
        | Error err -> check bool "failure is surfaced" true (String.length err > 0));
       check bool
         "detector remains latched after failed resume"
         true
         (Masc.Keeper_no_progress_loop_detector.is_latched ~keeper_name);
       check bool
         "live recovery stimulus remains absent after failed resume"
         false
         (queue_contains_post_id
            (Masc.Keeper_registry_event_queue.snapshot
               ~base_path:config.base_path
               keeper_name)
            recovery_post_id);
       (match paused_meta.runtime.last_blocker with
        | Some { Keeper_meta_contract.klass = Keeper_meta_contract.No_progress_loop; _ } ->
          ()
        | Some _ -> fail "expected no_progress meta blocker to remain"
        | None -> fail "expected meta blocker to remain");
       match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
       | Some entry ->
         (match entry.Masc.Keeper_registry.last_failure_reason with
          | Some
              (Masc.Keeper_registry.Provider_runtime_error
                { code = failure_code; _ })
            when String.equal
                   failure_code
                   Masc.Keeper_unified_turn_no_progress.failure_reason_code ->
            ()
          | Some _ -> fail "expected no_progress failure reason to remain"
          | None -> fail "expected failure reason to remain")
       | None -> fail "expected registered keeper")

let test_wakeup_directive_persists_no_progress_meta_clear () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "masc-no-progress-wakeup-" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_no_progress_loop_detector.reset_all_for_test ();
      cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "no-progress-wakeup" in
       let blocker =
         Keeper_meta_contract.blocker_info_of_class
           ~detail:"latched"
           Keeper_meta_contract.No_progress_loop
       in
       let meta =
         make_meta keeper_name
         |> Keeper_meta_contract.map_runtime (fun rt ->
           { rt with last_blocker = Some blocker })
       in
       Masc.Keeper_registry.clear ();
       ignore (Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       Masc.Keeper_registry.set_failure_reason
         ~base_path:config.base_path
         keeper_name
         (Some
            (Masc.Keeper_registry.Provider_runtime_error
               { code = Masc.Keeper_unified_turn_no_progress.failure_reason_code
               ; detail = "latched"
               ; provider_id = None
               ; http_status = None
               ; runtime_id = None
               ; reason = None
               }));
       Masc.Keeper_keepalive.process_directive ~agent_name:keeper_name "wakeup";
       match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
       | Some entry ->
         (match entry.Masc.Keeper_registry.meta.runtime.last_blocker with
          | None -> ()
          | Some _ -> fail "expected wakeup to persist no_progress meta clear");
         (match entry.Masc.Keeper_registry.last_failure_reason with
          | None -> ()
          | Some _ -> fail "expected wakeup to clear no_progress failure reason")
       | None -> fail "expected registered keeper")

let test_resume_directive_persist_failure_keeps_completion_contract_pause () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "masc-completion-resume-persist-fail-" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "completion-resume-persist-fail" in
       let blocker =
         Keeper_meta_contract.blocker_info_of_class
           ~detail:"completion contract violated"
           Keeper_meta_contract.Completion_contract_violation
       in
       let meta =
         { (make_meta keeper_name
            |> Keeper_meta_contract.map_runtime (fun rt ->
              { rt with last_blocker = Some blocker }))
           with
           paused = true
         }
       in
       Masc.Keeper_registry.clear ();
       let entry =
         Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta
       in
       let paused_entry =
         { entry with
           phase = Keeper_state_machine.Paused
         ; conditions =
             { entry.conditions with
               Keeper_state_machine.operator_paused = true
             }
         }
       in
       (match
          Masc.Keeper_registry.put_entry
            ~base_path:config.base_path
            keeper_name
            paused_entry
        with
        | Ok () -> ()
        | Error err ->
          fail
            ("seed paused registry entry: "
             ^ Masc.Keeper_registry.registry_entry_validation_error_to_string err));
       Masc.Keeper_registry.set_failure_reason
         ~base_path:config.base_path
         keeper_name
         (Some
            (Masc.Keeper_registry.Completion_contract_violation
               { detail = "completion contract violated" }));
       let keeper_json_path =
         Filename.concat
           (Filename.concat
              (Common.masc_dir_from_base_path ~base_path:config.base_path)
              "keepers")
           (keeper_name ^ ".json")
       in
       Unix.mkdir keeper_json_path 0o755;
       Masc.Keeper_keepalive.process_directive ~agent_name:keeper_name "resume";
       (match Masc.Keeper_registry.get_phase ~base_path:config.base_path keeper_name with
        | Some Keeper_state_machine.Paused -> ()
        | Some phase ->
          fail
            ("expected failed persistence to avoid Operator_resume, got phase "
             ^ Keeper_state_machine.phase_to_string phase)
        | None -> fail "expected registry phase");
       match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
       | Some entry ->
         check bool
           "registry meta remains paused"
           true
           entry.Masc.Keeper_registry.meta.paused;
         (match entry.Masc.Keeper_registry.meta.runtime.last_blocker with
          | Some
              { Keeper_meta_contract.klass =
                  Keeper_meta_contract.Completion_contract_violation
              ; _
              } -> ()
          | Some _ -> fail "expected completion-contract blocker to remain"
          | None -> fail "expected completion-contract blocker to remain");
         (match entry.Masc.Keeper_registry.last_failure_reason with
          | Some (Masc.Keeper_registry.Completion_contract_violation _) -> ()
          | Some _ -> fail "expected completion-contract failure reason to remain"
          | None -> fail "expected failed persistence to restore failure reason")
       | None -> fail "expected registered keeper")

let test_direct_success_clears_no_progress_pause () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "masc-no-progress-direct-success-" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_no_progress_loop_detector.reset_all_for_test ();
      Masc.Keeper_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "no-progress-direct-success" in
       let blocker =
         Keeper_meta_contract.blocker_info_of_class
           ~detail:"latched"
           Keeper_meta_contract.No_progress_loop
       in
       let meta =
         { (make_meta keeper_name
            |> Keeper_meta_contract.map_runtime (fun rt ->
              { rt with last_blocker = Some blocker }))
           with
           paused = true
         }
       in
       Masc.Keeper_registry.clear ();
       ignore (Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       ignore
         (Masc.Keeper_no_progress_loop_detector.record_turn
            ~threshold_override:1
            ~keeper_name
            ~made_progress:false
            ());
       Masc.Keeper_registry.set_failure_reason
         ~base_path:config.base_path
         keeper_name
         (Some
            (Masc.Keeper_registry.Provider_runtime_error
               { code = Masc.Keeper_unified_turn_no_progress.failure_reason_code
               ; detail = "latched"
               ; provider_id = None
               ; http_status = None
               ; runtime_id = None
               ; reason = None
               }));
       let recovered_meta =
         Masc.Keeper_turn.For_testing.clear_direct_success_no_progress_pause
           ~config
           ~pre_turn_meta:meta
           ~result:(run_result ())
           meta
       in
       check bool "direct success resumes no-progress pause" false recovered_meta.paused;
       check bool
         "detector reset by direct success"
         false
         (Masc.Keeper_no_progress_loop_detector.is_latched ~keeper_name);
       (match recovered_meta.runtime.last_blocker with
        | None -> ()
        | Some _ -> fail "expected direct success to clear no_progress meta blocker");
       match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
       | Some entry ->
         check bool
           "registry meta resumed"
           false
           entry.Masc.Keeper_registry.meta.paused;
         (match entry.Masc.Keeper_registry.last_failure_reason with
          | None -> ()
         | Some _ -> fail "expected direct success to clear no_progress failure reason")
       | None -> fail "expected registered keeper")

let test_direct_success_clears_no_progress_pause_after_blocker_overwrite () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "masc-no-progress-direct-success-overwrite-" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_no_progress_loop_detector.reset_all_for_test ();
      Masc.Keeper_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "no-progress-direct-success-overwrite" in
       let blocker =
         Keeper_meta_contract.blocker_info_of_class
           ~detail:"timeout overwritten no-progress blocker"
           Keeper_meta_contract.Turn_timeout
       in
       let meta =
         { (make_meta keeper_name
            |> Keeper_meta_contract.map_runtime (fun rt ->
              { rt with last_blocker = Some blocker }))
           with
           paused = true
         }
       in
       Masc.Keeper_registry.clear ();
       ignore (Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       ignore
         (Masc.Keeper_no_progress_loop_detector.record_turn
            ~threshold_override:1
            ~keeper_name
            ~made_progress:false
            ());
       Masc.Keeper_registry.set_failure_reason
         ~base_path:config.base_path
         keeper_name
         (Some
            (Masc.Keeper_registry.Provider_runtime_error
               { code = Masc.Keeper_unified_turn_no_progress.failure_reason_code
               ; detail = "latched"
               ; provider_id = None
               ; http_status = None
               ; runtime_id = None
               ; reason = None
               }));
       let recovered_meta =
         Masc.Keeper_turn.For_testing.clear_direct_success_no_progress_pause
           ~config
           ~pre_turn_meta:meta
           ~result:(run_result ())
           meta
       in
       check bool
         "direct success resumes no-progress pause after blocker overwrite"
         false
         recovered_meta.paused;
       check bool
         "detector reset after blocker overwrite"
         false
         (Masc.Keeper_no_progress_loop_detector.is_latched ~keeper_name);
       (match recovered_meta.runtime.last_blocker with
        | Some { Keeper_meta_contract.klass = Turn_timeout; detail } ->
          check string "non-no-progress blocker preserved" blocker.detail detail
        | Some _ -> fail "expected overwritten Turn_timeout blocker to remain"
        | None -> fail "expected non-no-progress blocker to remain");
       match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
       | Some entry ->
         check bool
           "registry meta resumed after blocker overwrite"
           false
           entry.Masc.Keeper_registry.meta.paused;
         (match entry.Masc.Keeper_registry.last_failure_reason with
          | None -> ()
         | Some _ -> fail "expected overwritten no-progress failure reason to clear")
       | None -> fail "expected registered keeper")

let test_direct_success_operator_pause_keeps_no_progress_pause () =
  let result =
    run_result ~operator_disposition:(Some pause_operator_disposition) ()
  in
  check bool
    "operator pause disposition cannot clear no-progress pause"
    false
    (Masc.Keeper_turn.For_testing.direct_success_may_clear_no_progress_pause
       result)

let test_direct_success_non_healthy_pass_keeps_no_progress_pause () =
  let result =
    run_result ~operator_disposition:(Some non_healthy_pass_operator_disposition) ()
  in
  check bool
    "non-healthy pass disposition cannot clear no-progress pause"
    false
    (Masc.Keeper_turn.For_testing.direct_success_may_clear_no_progress_pause
       result)

let test_direct_success_pass_next_model_keeps_no_progress_pause () =
  let result =
    run_result
      ~response_text:""
      ~operator_disposition:(Some pass_next_model_operator_disposition)
      ~tool_calls:
        [ tool_call
            ~typed_outcome:Keeper_tool_outcome.Progress
            "masc_deliver"
        ]
      ()
  in
  check bool
    "pass_next_model disposition cannot clear no-progress pause"
    false
    (Masc.Keeper_turn.For_testing.direct_success_may_clear_no_progress_pause
       result)

let test_direct_success_passive_only_no_visible_keeps_no_progress_pause () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "masc-no-progress-direct-success-passive-" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_no_progress_loop_detector.reset_all_for_test ();
      Masc.Keeper_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "no-progress-direct-success-passive" in
       let blocker =
         Keeper_meta_contract.blocker_info_of_class
           ~detail:"latched"
           Keeper_meta_contract.No_progress_loop
       in
       let meta =
         { (make_meta keeper_name
            |> Keeper_meta_contract.map_runtime (fun rt ->
              { rt with last_blocker = Some blocker }))
           with
           paused = true
         }
       in
       Masc.Keeper_registry.clear ();
       ignore (Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       ignore
         (Masc.Keeper_no_progress_loop_detector.record_turn
            ~threshold_override:1
            ~keeper_name
            ~made_progress:false
            ());
       Masc.Keeper_registry.set_failure_reason
         ~base_path:config.base_path
         keeper_name
         (Some
            (Masc.Keeper_registry.Provider_runtime_error
               { code = Masc.Keeper_unified_turn_no_progress.failure_reason_code
               ; detail = "latched"
               ; provider_id = None
               ; http_status = None
               ; runtime_id = None
               ; reason = None
               }));
       let result =
         run_result
           ~response_text:""
           ~tool_calls:
             [ tool_call
                 ~typed_outcome:Keeper_tool_outcome.Progress
                 "keeper_tasks_list" ]
           ()
       in
       let recovered_meta =
         Masc.Keeper_turn.For_testing.clear_direct_success_no_progress_pause
           ~config
           ~pre_turn_meta:meta
           ~result
           meta
       in
       check bool
         "passive-only no-visible direct success stays paused"
         true
         recovered_meta.paused;
       check bool
         "passive-only no-visible direct success keeps detector latched"
         true
         (Masc.Keeper_no_progress_loop_detector.is_latched ~keeper_name);
       (match recovered_meta.runtime.last_blocker with
        | Some
            { Keeper_meta_contract.klass = Keeper_meta_contract.No_progress_loop
            ; detail
            } ->
          check string "no-progress blocker preserved" blocker.detail detail
        | Some _ -> fail "expected no-progress blocker to remain"
        | None -> fail "expected no-progress blocker to remain");
       match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
       | Some entry ->
         check bool
           "registry meta remains paused after passive-only direct success"
           true
           entry.Masc.Keeper_registry.meta.paused;
         (match entry.Masc.Keeper_registry.last_failure_reason with
          | Some (Masc.Keeper_registry.Provider_runtime_error { code; _ })
            when String.equal
                   code
                   Masc.Keeper_unified_turn_no_progress.failure_reason_code -> ()
          | Some _ -> fail "expected no_progress failure reason to remain"
          | None -> fail "expected no_progress failure reason to remain")
       | None -> fail "expected registered keeper")

let test_direct_success_persist_failure_keeps_no_progress_pause () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "masc-no-progress-direct-success-persist-fail-" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_no_progress_loop_detector.reset_all_for_test ();
      Masc.Keeper_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "no-progress-direct-success-persist-fail" in
       let blocker =
         Keeper_meta_contract.blocker_info_of_class
           ~detail:"latched"
           Keeper_meta_contract.No_progress_loop
       in
       let meta =
         { (make_meta keeper_name
            |> Keeper_meta_contract.map_runtime (fun rt ->
              { rt with last_blocker = Some blocker }))
           with
           paused = true
         }
       in
       Masc.Keeper_registry.clear ();
       let entry =
         Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta
       in
       let paused_entry =
         { entry with
           phase = Keeper_state_machine.Paused
         ; conditions =
             { entry.conditions with
               Keeper_state_machine.operator_paused = true
             }
         }
       in
       (match
          Masc.Keeper_registry.put_entry
            ~base_path:config.base_path
            keeper_name
            paused_entry
        with
        | Ok () -> ()
        | Error err ->
          fail
            ("seed paused registry entry: "
             ^ Masc.Keeper_registry.registry_entry_validation_error_to_string err));
       ignore
         (Masc.Keeper_turn_livelock.record_turn_start
            ~base_path:config.base_path
            ~keeper:keeper_name
            ~turn_id:42);
       ignore
         (Masc.Keeper_no_progress_loop_detector.record_turn
            ~threshold_override:1
            ~keeper_name
            ~made_progress:false
            ());
       Masc.Keeper_registry.set_failure_reason
         ~base_path:config.base_path
         keeper_name
         (Some
            (Masc.Keeper_registry.Provider_runtime_error
               { code = Masc.Keeper_unified_turn_no_progress.failure_reason_code
               ; detail = "latched"
               ; provider_id = None
               ; http_status = None
               ; runtime_id = None
               ; reason = None
               }));
       let invalid_meta = { meta with agent_name = "" } in
       let recovered_meta =
         Masc.Keeper_turn.For_testing.clear_direct_success_no_progress_pause
           ~config
           ~pre_turn_meta:invalid_meta
           ~result:(run_result ())
           invalid_meta
       in
       check bool "failed persistence keeps returned meta paused" true recovered_meta.paused;
       check bool
         "failed persistence keeps detector latched"
         true
         (Masc.Keeper_no_progress_loop_detector.is_latched ~keeper_name);
       (match
          Masc.Keeper_turn_livelock.current_state
            ~base_path:config.base_path
            ~keeper:keeper_name
        with
        | Some _ -> ()
        | None -> fail "expected failed persistence to keep livelock state");
       (match Masc.Keeper_registry.get_phase ~base_path:config.base_path keeper_name with
        | Some Keeper_state_machine.Paused -> ()
        | Some phase ->
          fail
            ("expected failed persistence to avoid Operator_resume, got phase "
             ^ Keeper_state_machine.phase_to_string phase)
        | None -> fail "expected registry phase");
       match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
       | Some entry ->
         check bool
           "registry meta remains paused"
           true
           entry.Masc.Keeper_registry.meta.paused;
         (match entry.Masc.Keeper_registry.last_failure_reason with
          | Some (Masc.Keeper_registry.Provider_runtime_error { code; _ })
            when String.equal
                   code
                   Masc.Keeper_unified_turn_no_progress.failure_reason_code -> ()
          | Some _ -> fail "expected no_progress failure reason to remain"
          | None -> fail "expected failed persistence to keep failure reason")
       | None -> fail "expected registered keeper")

let test_direct_success_leaves_unrelated_pause_intact () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "masc-no-progress-direct-success-unrelated-" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_no_progress_loop_detector.reset_all_for_test ();
      Masc.Keeper_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "no-progress-direct-success-unrelated" in
       let blocker =
         Keeper_meta_contract.blocker_info_of_class
           ~detail:"ordinary timeout pause"
           Keeper_meta_contract.Turn_timeout
       in
       let meta =
         { (make_meta keeper_name
            |> Keeper_meta_contract.map_runtime (fun rt ->
              { rt with last_blocker = Some blocker }))
           with
           paused = true
         ; auto_resume_after_sec = Some 60.0
         }
       in
       Masc.Keeper_registry.clear ();
       ignore (Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       let recovered_meta =
         Masc.Keeper_turn.For_testing.clear_direct_success_no_progress_pause
           ~config
           ~pre_turn_meta:meta
           ~result:(run_result ())
           meta
       in
       check bool "unrelated pause stays paused" true recovered_meta.paused;
       check
         (option (float 0.001))
         "unrelated auto-resume stays intact"
         (Some 60.0)
         recovered_meta.auto_resume_after_sec;
       check bool
         "detector remains unlatched for unrelated pause"
         false
         (Masc.Keeper_no_progress_loop_detector.is_latched ~keeper_name);
       (match recovered_meta.runtime.last_blocker with
        | Some { Keeper_meta_contract.klass = Turn_timeout; detail } ->
          check string "unrelated blocker preserved" blocker.detail detail
        | Some _ -> fail "expected unrelated Turn_timeout blocker to remain"
        | None -> fail "expected unrelated blocker to remain");
       match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
       | Some entry ->
         check bool
           "registry meta remains paused"
           true
           entry.Masc.Keeper_registry.meta.paused;
         (match entry.Masc.Keeper_registry.last_failure_reason with
          | None -> ()
          | Some _ -> fail "expected no unrelated failure reason")
       | None -> fail "expected registered keeper")

let test_idle_detected_repeated_failure_pauses_keeper () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "masc-idle-detected-pause-" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "idle-detected-paused" in
       let meta = make_meta keeper_name in
       Masc.Keeper_registry.clear ();
       ignore (Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       let err =
         Agent_sdk.Error.Agent
           (Agent_sdk.Error.IdleDetected { consecutive_idle_turns = 4 })
       in
       for _ = 1 to Masc.Keeper_behavioral_regime.turn_fail_streak_threshold do
         Masc.Keeper_unified_turn_failure.record_failure_and_maybe_escalate
           ~config
           ~meta
           ~updated_meta:meta
           ~is_auto_recoverable:false
           ~err
           ~error_text:(Agent_sdk.Error.to_string err)
       done;
       match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
       | Some entry ->
         let paused_meta = entry.Masc.Keeper_registry.meta in
         check bool "registry meta paused" true paused_meta.paused;
         check
           (option (float 0.001))
           "safety pause has no auto-resume"
           None
           paused_meta.auto_resume_after_sec;
         (match paused_meta.runtime.last_blocker with
          | Some { Keeper_meta_contract.klass = Sdk_idle_detected; detail } ->
            check
              string
              "blocker detail"
              "idle loop detected: consecutive_idle_turns=4; auto-paused after repeated idle turns; operator resume clears the idle latch"
              detail
       | Some _ -> fail "expected Sdk_idle_detected blocker"
       | None -> fail "expected idle-detected blocker")
       | None -> fail "expected registered keeper")

let test_runtime_pause_threshold_override_controls_idle_auto_pause () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_runtime_config (runtime_toml_with_pause_threshold 2) @@ fun () ->
  let base_path = temp_dir "masc-idle-detected-runtime-threshold-" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "idle-detected-runtime-threshold" in
       let meta = make_meta keeper_name in
       Masc.Keeper_registry.clear ();
       ignore (Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       let err =
         Agent_sdk.Error.Agent
           (Agent_sdk.Error.IdleDetected { consecutive_idle_turns = 4 })
       in
       Masc.Keeper_unified_turn_failure.record_failure_and_maybe_escalate
         ~config
         ~meta
         ~updated_meta:meta
         ~is_auto_recoverable:false
         ~err
         ~error_text:(Agent_sdk.Error.to_string err);
       (match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
        | Some entry ->
          check bool "not paused before runtime threshold" false
            entry.Masc.Keeper_registry.meta.paused
        | None -> fail "expected registered keeper after first failure");
       Masc.Keeper_unified_turn_failure.record_failure_and_maybe_escalate
         ~config
         ~meta
         ~updated_meta:meta
         ~is_auto_recoverable:false
         ~err
         ~error_text:(Agent_sdk.Error.to_string err);
       match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
       | Some entry ->
         check bool "paused at runtime threshold" true
           entry.Masc.Keeper_registry.meta.paused
       | None -> fail "expected registered keeper after threshold")

let test_legacy_last_blocker_pair_rejected () =
  let legacy_json =
    match legacy_base_json "legacy-blocker-pair" with
    | `Assoc fields ->
      `Assoc
        (fields
         @ [
           "last_blocker", `String "turn wall-clock timeout exceeded";
         ])
    | json -> json
  in
  match Keeper_meta_json_parse.meta_of_json legacy_json with
  | Ok _ -> fail "legacy blocker pair should be rejected"
  | Error msg ->
    check bool "rejects legacy blocker string" true
      (String.contains msg ':')

let test_legacy_last_blocker_string_rejected () =
  let legacy_json =
    match legacy_base_json "legacy-blocker-string" with
    | `Assoc fields ->
      `Assoc
        (fields @ [ "last_blocker", `String "turn wall-clock timeout exceeded" ])
    | json -> json
  in
  match Keeper_meta_json_parse.meta_of_json legacy_json with
  | Ok _ -> fail "legacy string last_blocker should be rejected"
  | Error msg ->
    check string
      "rejects string last_blocker"
      "removed keeper meta field shape is no longer supported: \
       last_blocker:string. Use structured last_blocker object."
      msg

let () =
  run "keeper_auto_pause_blocker_persist_12683"
    [
      ( "blocker_class labels",
        [
          test_case "Turn_timeout roundtrip" `Quick
            test_turn_timeout_blocker_class_roundtrip;
          test_case "Stale_fleet_batch roundtrip" `Quick
            test_stale_fleet_batch_blocker_class_roundtrip;
          test_case "Capacity_backpressure roundtrip" `Quick
            test_capacity_backpressure_blocker_class_roundtrip;
        ] );
      ( "meta JSON roundtrip",
        [
          test_case "OAS budget blocker survives serialization" `Quick
            test_meta_json_roundtrip_with_auto_pause_blocker;
          test_case "stale storm blocker survives serialization" `Quick
            test_meta_json_roundtrip_with_stale_storm_blocker;
          test_case "legacy blocker pair rejected" `Quick
            test_legacy_last_blocker_pair_rejected;
          test_case "legacy blocker string rejected" `Quick
            test_legacy_last_blocker_string_rejected;
        ] );
      ( "no_progress loop",
        [
          test_case "loop detection pauses keeper for manual resume" `Quick
            test_no_progress_loop_detection_pauses_keeper;
          test_case "loop detection releases owned active task" `Quick
            test_no_progress_loop_detection_releases_owned_active_task;
          test_case "operator resume clears no-progress latch" `Quick
            test_operator_resume_clears_no_progress_loop_latch;
          test_case
            "operator resume keeps no-progress state on drop failure"
            `Quick
            test_operator_resume_keeps_no_progress_state_on_drop_failure;
          test_case "wakeup directive persists no-progress meta clear" `Quick
            test_wakeup_directive_persists_no_progress_meta_clear;
          test_case
            "resume directive persistence failure keeps completion-contract pause"
            `Quick
            test_resume_directive_persist_failure_keeps_completion_contract_pause;
          test_case "direct success clears no-progress pause" `Quick
            test_direct_success_clears_no_progress_pause;
          test_case
            "direct success clears no-progress pause after blocker overwrite"
            `Quick
            test_direct_success_clears_no_progress_pause_after_blocker_overwrite;
          test_case
            "direct success operator pause keeps no-progress pause"
            `Quick
            test_direct_success_operator_pause_keeps_no_progress_pause;
          test_case
            "direct success non-healthy pass keeps no-progress pause"
            `Quick
            test_direct_success_non_healthy_pass_keeps_no_progress_pause;
          test_case
            "direct success pass-next-model keeps no-progress pause"
            `Quick
            test_direct_success_pass_next_model_keeps_no_progress_pause;
          test_case
            "direct success passive-only no-visible keeps no-progress pause"
            `Quick
            test_direct_success_passive_only_no_visible_keeps_no_progress_pause;
          test_case
            "direct success persistence failure keeps no-progress pause"
            `Quick
            test_direct_success_persist_failure_keeps_no_progress_pause;
          test_case "direct success leaves unrelated pause intact" `Quick
            test_direct_success_leaves_unrelated_pause_intact;
        ] );
      ( "completion_contract pause",
        [
          test_case "pause sync releases owned active task" `Quick
            test_completion_contract_pause_sync_releases_owned_active_task;
        ] );
      ( "idle-detected loop",
        [
          test_case "repeated IdleDetected pauses keeper for manual resume" `Quick
            test_idle_detected_repeated_failure_pauses_keeper;
          test_case "runtime [pause] threshold controls idle auto-pause" `Quick
            test_runtime_pause_threshold_override_controls_idle_auto_pause;
        ] );
    ]
