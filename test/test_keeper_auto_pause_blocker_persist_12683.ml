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
         "manual pause has no auto-resume"
         None
       paused_meta.auto_resume_after_sec;
       (match paused_meta.runtime.last_blocker with
        | Some { Keeper_meta_contract.klass = No_progress_loop; detail } ->
          check
            string
            "blocker detail"
            "no_progress loop detected: streak=10 threshold=10; keeper paused until operator resume clears the no-progress latch"
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
          | None -> fail "expected no_progress failure reason")
       | None -> fail "expected registered keeper")

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
       check bool
         "detector latched before resume"
         true
         (Masc.Keeper_no_progress_loop_detector.is_latched ~keeper_name);
       let resumed_meta =
         Masc.Keeper_unified_turn_no_progress.clear_for_operator_resume
           ~base_path:config.base_path
           meta
       in
       check bool
         "detector reset by operator resume"
         false
         (Masc.Keeper_no_progress_loop_detector.is_latched ~keeper_name);
       (match resumed_meta.runtime.last_blocker with
        | None -> ()
        | Some _ -> fail "expected no_progress meta blocker to clear");
       match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
       | Some entry ->
         (match entry.Masc.Keeper_registry.last_failure_reason with
          | None -> ()
          | Some _ -> fail "expected no_progress failure reason to clear")
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
           phase = Masc.Keeper_state_machine.Paused
         ; conditions =
             { entry.conditions with
               Masc.Keeper_state_machine.operator_paused = true
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
        | Some Masc.Keeper_state_machine.Paused -> ()
        | Some phase ->
          fail
            ("expected failed persistence to avoid Operator_resume, got phase "
             ^ Masc.Keeper_state_machine.phase_to_string phase)
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
           "manual pause has no auto-resume"
           None
           paused_meta.auto_resume_after_sec;
         (match paused_meta.runtime.last_blocker with
          | Some { Keeper_meta_contract.klass = Sdk_idle_detected; detail } ->
            check
              string
              "blocker detail"
              "idle loop detected: consecutive_idle_turns=4; manual pause applied"
              detail
          | Some _ -> fail "expected Sdk_idle_detected blocker"
          | None -> fail "expected idle-detected blocker")
       | None -> fail "expected registered keeper")

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
          test_case "operator resume clears no-progress latch" `Quick
            test_operator_resume_clears_no_progress_loop_latch;
          test_case "wakeup directive persists no-progress meta clear" `Quick
            test_wakeup_directive_persists_no_progress_meta_clear;
          test_case "direct success clears no-progress pause" `Quick
            test_direct_success_clears_no_progress_pause;
          test_case
            "direct success clears no-progress pause after blocker overwrite"
            `Quick
            test_direct_success_clears_no_progress_pause_after_blocker_overwrite;
          test_case
            "direct success persistence failure keeps no-progress pause"
            `Quick
            test_direct_success_persist_failure_keeps_no_progress_pause;
          test_case "direct success leaves unrelated pause intact" `Quick
            test_direct_success_leaves_unrelated_pause_intact;
        ] );
      ( "idle-detected loop",
        [
          test_case "repeated IdleDetected pauses keeper for manual resume" `Quick
            test_idle_detected_repeated_failure_pauses_keeper;
        ] );
    ]
