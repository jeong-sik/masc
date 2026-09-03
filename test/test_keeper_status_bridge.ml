open Masc

let make_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String "verifier");
          ("trace_id", `String "trace-verifier");
        ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("meta_of_json_fixture failed: " ^ err)
;;

 let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)
;;

let runtime_toml =
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
|}
;;

let init_runtime_default_for_tests () =
  let path = Filename.temp_file "keeper_status_bridge_runtime_" ".toml" in
  write_file path runtime_toml;
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error e -> Alcotest.failf "Runtime.init_default failed: %s" e
;;

let defaults_with_prompt_fields =
  { Keeper_types_profile.empty_keeper_profile_defaults with
    instructions = Some "profile instructions"
  ; mention_targets = [ "profile-target" ]
  }
;;

 let test_empty_live_meta_does_not_mask_profile_defaults_as_overrides () =
  init_runtime_default_for_tests ();
  let meta =
    { (make_meta ()) with
      instructions = "";
      mention_targets = [];
    }
  in
  Alcotest.(check (list string))
    "empty live prompt fields inherit TOML defaults without override drift"
    []
    (Keeper_status_bridge.live_override_fields meta defaults_with_prompt_fields)
;;

let test_shutdown_phase_names_are_pinned () =
  (* These strings go on the wire in keeper_status. A consumer waits for a
     terminal by comparing against them, so renaming one silently breaks that
     wait — the compiler cannot see a string comparison in a Python runner
     (#29181). Exhaustiveness is the compiler's job; this pins the values. *)
  let check expected phase =
    Alcotest.(check string)
      expected
      expected
      (Keeper_shutdown_types.phase_to_string phase)
  in
  check "prepared" Keeper_shutdown_types.Prepared;
  check "joining_lanes" Keeper_shutdown_types.Joining_lanes;
  check "joined_idle" Keeper_shutdown_types.Joined_idle
;;

(* [quiet_reason] and [next_action_path] cross into the dashboard as bare
   strings. There the union is checked by membership: an unlisted
   [next_action_path] makes normalizeKeeperDiagnostic drop the whole
   diagnostic, and an unlisted [quiet_reason] silently erases the reason. The
   compiler cannot see a TypeScript union, so the match below pins each
   constructor's wire form — adding one is a compile error here, and the list
   it must be added to is the same list dashboard/src/types/core.ts mirrors. *)
let quiet_reason_wire =
  let open Keeper_status_runtime in
  [ Proactive_disabled; Keepalive_not_running; Starting_up; Never_started ]
  |> List.map (fun reason ->
       ( match reason with
         | Proactive_disabled -> "disabled"
         | Keepalive_not_running -> "not_running"
         | Starting_up -> "startup"
         | Never_started -> "never_started" )
       , keeper_quiet_reason_to_string reason )
;;

let next_action_path_wire =
  let open Keeper_status_runtime in
  [ Auto_restart; Recover; Probe; Direct_message ]
  |> List.map (fun path ->
       ( match path with
         | Auto_restart -> "auto_restart"
         | Recover -> "recover"
         | Probe -> "probe"
         | Direct_message -> "direct_message" )
       , keeper_next_action_path_to_string path )
;;

let test_quiet_reason_wire_strings_are_pinned () =
  List.iter
    (fun (expected, actual) -> Alcotest.(check string) expected expected actual)
    quiet_reason_wire
;;

let test_next_action_path_wire_strings_are_pinned () =
  List.iter
    (fun (expected, actual) -> Alcotest.(check string) expected expected actual)
    next_action_path_wire
;;

let shutdown_operation_with_phase phase =
  let trace_id =
    match Keeper_id.Trace_id.of_string "trace-status-bridge-fence-test" with
    | Ok trace_id -> trace_id
    | Error detail -> Alcotest.failf "trace id rejected: %s" detail
  in
  { Keeper_shutdown_types.schema_version =
      Keeper_shutdown_types.schema_version
  ; revision = 1
  ; operation_id = Keeper_shutdown_types.Operation_id.generate ()
  ; keeper_name = "verifier"
  ; lane_ownership = Keeper_shutdown_types.Dormant_meta
  ; trace_id
  ; actor = "test"
  ; cleanup_intent =
      { Keeper_shutdown_types.reason =
          Keeper_shutdown_types.Operator_stop_remove_meta
      ; remove_session = true
      }
  ; turn_disposition = Keeper_shutdown_types.No_inflight_turn
  ; expected_backlog_version = 0
  ; owned_task_ids = []
  ; join_evidence = None
  ; phase
  ; created_at = Masc_domain.now_iso ()
  ; updated_at = Masc_domain.now_iso ()
  }
;;

let test_admission_fence_is_any_not_latest () =
  (* keeper_status projects List.exists over the records, not the newest one:
     admission is refused while any record still fences, so a consumer that
     read only the latest phase would restart into a fence (#29181). *)
  let fencing =
    shutdown_operation_with_phase Keeper_shutdown_types.Joined_idle
  in
  let settled =
    shutdown_operation_with_phase
      (Keeper_shutdown_types.Superseded
         (Keeper_shutdown_types.Operator_metadata_update { actor = "test" }))
  in
  Alcotest.(check bool)
    "a settled record alone does not fence"
    false
    (List.exists Keeper_shutdown_types.requires_admission_fence [ settled ]);
  Alcotest.(check bool)
    "one fencing record fences the whole set"
    true
    (List.exists
       Keeper_shutdown_types.requires_admission_fence
       [ settled; fencing ])
;;

let test_nonempty_live_meta_still_reports_profile_override () =
  init_runtime_default_for_tests ();
  let meta =
    { (make_meta ()) with
      instructions = "live instructions";
      mention_targets = [ "live-target" ];
    }
  in
  Alcotest.(check (list string))
    "non-empty live prompt fields still surface as overrides"
    [ "prompt.instructions"; "workspace.mention_targets" ]
    (Keeper_status_bridge.live_override_fields meta defaults_with_prompt_fields)
;;

let test_age_seconds_preserves_missing_timestamp () =
  Alcotest.check (Alcotest.option (Alcotest.float 0.0001))
    "zero sentinel becomes missing age"
    None
    (Keeper_status_metrics.age_seconds_opt ~now_ts:100.0 0.0);
  Alcotest.check (Alcotest.option (Alcotest.float 0.0001))
    "negative sentinel becomes missing age"
    None
    (Keeper_status_metrics.age_seconds_opt ~now_ts:100.0 (-1.0));
  Alcotest.check (Alcotest.option (Alcotest.float 0.0001))
    "real timestamp remains an age"
    (Some 25.0)
    (Keeper_status_metrics.age_seconds_opt ~now_ts:100.0 75.0)
;;

(* #32971 Root B: the Turn row the metrics producer writes today carries
   neither [generation] (removed by #29590) nor [handoff_performed] (removed
   by #31522). While the summary required both, every Turn row was discarded
   and a Keeper with hundreds of turns reported turn_points 0. *)
let producer_shaped_turn_line ~channel =
  Yojson.Safe.to_string
    (`Assoc
      (Keeper_metrics_record.fields Keeper_metrics_record.Turn
      @ [ "ts", `String "2026-09-04T00:00:00Z"
        ; "ts_unix", `Float 100.0
        ; "channel", `String channel
        ; "trace_id", `String "trace-producer"
        ; "latency_ms", `Int 20
        ; "turn_mode", `String "text_response"
        ; "tool_call_count", `Int 0
        ; "tools_used", `List []
        ]))
;;

let test_producer_shaped_turn_rows_reach_the_summary () =
  let summary_field key =
    Keeper_status_metrics.summarize_metrics_lines
      [ producer_shaped_turn_line ~channel:"turn"
      ; producer_shaped_turn_line ~channel:"turn"
      ; producer_shaped_turn_line ~channel:"scheduled_autonomous"
      ]
    |> Keeper_status_metrics.metrics_summary_to_json
    |> Yojson.Safe.Util.member key
    |> Yojson.Safe.Util.to_int
  in
  Alcotest.(check int) "reactive rows raise turn_points" 2 (summary_field "turn_points");
  Alcotest.(check int)
    "autonomous rows raise proactive_points"
    1
    (summary_field "proactive_points");
  Alcotest.(check int) "every row is sampled" 3 (summary_field "sample_points")
;;

let test_summary_json_drops_the_retired_handoff_counters () =
  let json =
    Keeper_status_metrics.metrics_summary_to_json
      Keeper_status_metrics.empty_metrics_summary
  in
  let absent key = Yojson.Safe.Util.member key json = `Null in
  Alcotest.(check bool) "handoff_count is gone" true (absent "handoff_count");
  Alcotest.(check bool) "last_handoff is gone" true (absent "last_handoff")
;;

let test_tool_audit_cache_advances_from_negative_by_appended_rows () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  let base_path =
    Filename.temp_dir "keeper_status_tool_audit_cache_" ""
  in
  Fun.protect
    ~finally:(fun () ->
      Eio_guard.disable ();
      Fs_compat.remove_tree base_path)
    (fun () ->
      let config = Workspace.default_config base_path in
      let keeper_name = "tool-audit-cache" in
      let store =
        Keeper_types_support.keeper_metrics_store config keeper_name
      in
      let heartbeat sequence =
        `Assoc
          (Keeper_metrics_record.fields Keeper_metrics_record.Heartbeat
           @ [ "ts", `String "2026-07-30T05:00:00Z"
             ; "ts_unix", `Float 1_785_388_400.0
             ; "channel", `String "heartbeat"
             ; "sequence", `Int sequence
             ])
      in
      Dated_jsonl.append store (heartbeat 1);
      Alcotest.(check bool)
        "initial current-schema negative lookup"
        true
        (Option.is_none
           (Keeper_status_metrics.latest_tool_audit_snapshot_from_files
              config
              ~keeper_name));
      Dated_jsonl.append store (heartbeat 2);
      Alcotest.(check bool)
        "appended heartbeat preserves cached negative result"
        true
        (Option.is_none
           (Keeper_status_metrics.latest_tool_audit_snapshot_from_files
              config
              ~keeper_name));
      Dated_jsonl.append store
        (`Assoc
          (Keeper_metrics_record.fields Keeper_metrics_record.Turn
           @ [ "ts", `String "2026-07-30T05:00:01Z"
             ; "ts_unix", `Float 1_785_388_401.0
             ; "trace_id", `String "trace-tool-audit-cache"
             ; "channel", `String "turn"
             ; "turn_mode", `String "tool_use"
             ; "latency_ms", `Int 1
             ; "tool_call_count", `Int 1
             ; "tools_used", `List [ `String "masc_status" ]
             ]));
      match
        Keeper_status_metrics.latest_tool_audit_snapshot_from_files
          config
          ~keeper_name
      with
      | Some snapshot ->
          Alcotest.(check (list string))
            "new turn advances the incremental audit snapshot"
            [ "masc_status" ]
            snapshot.latest_tool_names
      | None -> Alcotest.fail "expected appended current-schema turn audit")
;;

let test_tool_audit_cache_invalidation_for_recreated_keeper () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  let base_path =
    Filename.temp_dir "keeper_status_tool_audit_recreated_" ""
  in
  Fun.protect
    ~finally:(fun () ->
      Eio_guard.disable ();
      Fs_compat.remove_tree base_path)
    (fun () ->
      let config = Workspace.default_config base_path in
      let keeper_name = "recreated-keeper" in
      let store =
        Keeper_types_support.keeper_metrics_store config keeper_name
      in
      let turn tool_name =
        `Assoc
          (Keeper_metrics_record.fields Keeper_metrics_record.Turn
           @ [ "ts", `String "2026-07-30T05:00:01Z"
             ; "ts_unix", `Float 1_785_388_401.0
             ; "trace_id", `String "trace-recreated-keeper"
             ; "channel", `String "turn"
             ; "turn_mode", `String "tool_use"
             ; "latency_ms", `Int 1
             ; "tool_call_count", `Int 1
             ; "tools_used", `List [ `String tool_name ]
             ])
      in
      let latest_tool_names () =
        match
          Keeper_status_metrics.latest_tool_audit_snapshot_from_files
            config
            ~keeper_name
        with
        | Some snapshot -> snapshot.latest_tool_names
        | None -> Alcotest.fail "expected current Keeper tool audit"
      in
      Dated_jsonl.append store (turn "old_tool");
      Alcotest.(check (list string))
        "initial Keeper audit"
        [ "old_tool" ]
        (latest_tool_names ());
      Dated_jsonl.prepare_for_directory_removal store;
      Keeper_status_metrics.invalidate_tool_audit_cache config ~keeper_name;
      Fs_compat.remove_tree
        (Keeper_types_support.keeper_metrics_dir config keeper_name);
      Dated_jsonl.append store (turn "new_tool");
      Alcotest.(check (list string))
        "recreated Keeper does not inherit deleted audit"
        [ "new_tool" ]
        (latest_tool_names ()))
;;

(* Every failure_reason the registry can hold, so a new variant lands here
   rather than reaching the trust snapshot as an undecodable string. The
   producer emits blocker_class as a string and the consumer parses it with
   Keeper_meta_contract.blocker_class_of_serialized_string; the two
   vocabularies are not the same set (#25797). *)
let every_failure_reason : Keeper_registry.failure_reason list =
  [ Keeper_registry.Heartbeat_consecutive_failures 3
  ; Keeper_registry.Turn_consecutive_failures 2
  ; Keeper_registry.Stale_termination_storm { count = 4 }
  ; Keeper_registry.Provider_runtime_error
      { code = "api_error_500"
      ; detail = "boom"
      ; provider_id = None
      ; http_status = Some 500
      ; runtime_id = None
      ; agent_core_timeout = None
      ; reason = None
      }
  ; (* The same constructor with the typed reason present. The registry wraps
       runtime exhaustion this way ([keeper_unified_turn_types.ml:100-112]), and
       reading only [code] made the status bridge's runtime_exhausted arm
       unreachable — every exhaustion arrived labelled provider_runtime_error
       (#30447). *)
    Keeper_registry.Provider_runtime_error
      { code = "connection_refused"
      ; detail = "boom"
      ; provider_id = None
      ; http_status = None
      ; runtime_id = Some "r1"
      ; agent_core_timeout = None
      ; reason = Some Keeper_meta_contract.Connection_refused
      }
  ; Keeper_registry.Turn_configuration_error
      { code = "missing_env_var"
      ; field = Some "OLLAMA_CLOUD_API_KEY"
      ; detail = "required environment variable is missing"
      }
  ; Keeper_registry.Turn_overflow_failure
  ; Keeper_registry.Operator_interrupt
  ; Keeper_registry.Exception "boom"
  ]
;;

(* The arm this reaches is [keeper_status_bridge.ml]'s runtime_attempts_exhausted
   label, which nothing could reach before: the producer stamped the string
   "provider_runtime_error" for exhaustion too. *)
let test_exhaustion_reaches_the_runtime_exhausted_class () =
  let reason =
    Keeper_registry.Provider_runtime_error
      { code = "dns_failure"
      ; detail = "no such host"
      ; provider_id = None
      ; http_status = None
      ; runtime_id = Some "r1"
      ; agent_core_timeout = None
      ; reason = Some Keeper_meta_contract.Dns_failure
      }
  in
  match Keeper_status_bridge.runtime_blocker_surface_of_failure_reason reason with
  | None -> Alcotest.fail "an exhaustion reason must produce a blocker surface"
  | Some surface ->
    Alcotest.(check string)
      "typed exhaustion is not flattened into provider_runtime_error"
      "runtime_exhausted"
      surface.Keeper_status_bridge.blocker_class

(* Without the typed reason the same constructor is a plain provider error, so
   the two must not collapse into one answer. *)
let test_provider_error_without_reason_stays_provider_error () =
  let reason =
    Keeper_registry.Provider_runtime_error
      { code = "api_error_500"
      ; detail = "boom"
      ; provider_id = None
      ; http_status = Some 500
      ; runtime_id = None
      ; agent_core_timeout = None
      ; reason = None
      }
  in
  match Keeper_status_bridge.runtime_blocker_surface_of_failure_reason reason with
  | None -> Alcotest.fail "a provider error must produce a blocker surface"
  | Some surface ->
    Alcotest.(check string)
      "a provider error without an exhaustion reason keeps its own class"
      "provider_runtime_error"
      surface.Keeper_status_bridge.blocker_class

let test_undecodable_blocker_classes_are_named_not_counted () =
  let undecodable =
    List.filter_map
      (fun reason ->
        match Keeper_status_bridge.runtime_blocker_surface_of_failure_reason reason with
        | None -> None
        | Some surface ->
          (match
             Keeper_meta_contract.blocker_class_of_serialized_string
               surface.Keeper_status_bridge.blocker_class
           with
           | Some _ -> None
           | None -> Some surface.Keeper_status_bridge.blocker_class))
      every_failure_reason
  in
  (* This is the gap the issue reports, pinned as a list rather than a count:
     when a class is taught to the decoder it leaves this list, and when a new
     producer class appears it joins it. Either way the diff names it. *)
  Alcotest.(check (slist string String.compare))
    "classes the trust-snapshot decoder does not know"
    [ "exception"
    ; "heartbeat_failures"
    ; "operator_interrupt"
    ; "provider_runtime_error"
    ; "stale_termination_storm"
    ; "turn_failures"
    ; "turn_configuration_error"
    ; "turn_overflow_failure"
    ]
    undecodable
;;

let test_decodable_blocker_classes_stay_decodable () =
  let decodable =
    List.filter_map
      (fun reason ->
        match Keeper_status_bridge.runtime_blocker_surface_of_failure_reason reason with
        | None -> None
        | Some surface ->
          (match
             Keeper_meta_contract.blocker_class_of_serialized_string
               surface.Keeper_status_bridge.blocker_class
           with
           | Some _ -> Some surface.Keeper_status_bridge.blocker_class
           | None -> None))
      every_failure_reason
  in
  (* One producer class decodes: runtime_exhausted, since #30447 stopped
     flattening a typed exhaustion reason into "provider_runtime_error". The
     rest are still the two-vocabulary gap this suite pins.

     This number is the point of the test — it was 0 when every producer class
     was undecodable, and the comment then said a class taught to the decoder
     "has to appear here". Raising it is that happening, not a regression. *)
  Alcotest.(check (list string))
    "producer classes that decode today"
    [ "runtime_exhausted" ]
    (List.sort_uniq String.compare decodable);
  Alcotest.(check bool)
    "the producer does emit classes"
    true
    (List.exists
       (fun reason ->
         Keeper_status_bridge.runtime_blocker_surface_of_failure_reason reason <> None)
       every_failure_reason)
;;

let () =
  Alcotest.run
    "keeper_status_bridge"
    [
( "timestamp age sentinel SSOT",
        [ Alcotest.test_case
            "missing timestamps do not become zero age"
            `Quick
            test_age_seconds_preserves_missing_timestamp
        ] );
      ( "metrics window producer contract",
        [ Alcotest.test_case
            "producer-shaped turn rows reach the summary"
            `Quick
            test_producer_shaped_turn_rows_reach_the_summary
        ; Alcotest.test_case
            "retired handoff counters are gone from the wire"
            `Quick
            test_summary_json_drops_the_retired_handoff_counters
        ] );
      ( "tool audit cache",
        [ Alcotest.test_case
            "negative snapshot advances from appended rows"
            `Quick
            test_tool_audit_cache_advances_from_negative_by_appended_rows;
          Alcotest.test_case
            "recreated Keeper does not inherit deleted audit"
            `Quick
            test_tool_audit_cache_invalidation_for_recreated_keeper
        ] );
      ( "profile default override provenance",
        [
          Alcotest.test_case
            "empty live identity inherits TOML without drift"
            `Quick
            test_empty_live_meta_does_not_mask_profile_defaults_as_overrides;
          Alcotest.test_case
            "non-empty live identity still reports override"
            `Quick
            test_nonempty_live_meta_still_reports_profile_override;
        ] );
      ( "shutdown operation phase projection",
        [
          Alcotest.test_case
            "phase names are pinned for wire consumers"
            `Quick
            test_shutdown_phase_names_are_pinned;
          Alcotest.test_case
            "admission fence is any-record, not latest"
            `Quick
            test_admission_fence_is_any_not_latest;
        ] );
      ( "keeper diagnostic wire vocabulary",
        [
          Alcotest.test_case
            "quiet_reason strings are pinned for the dashboard union"
            `Quick
            test_quiet_reason_wire_strings_are_pinned;
          Alcotest.test_case
            "next_action_path strings are pinned for the dashboard union"
            `Quick
            test_next_action_path_wire_strings_are_pinned;
        ] );
    ( "blocker_class_vocabulary"
    , [ Alcotest.test_case
          "undecodable producer classes are named"
          `Quick
          test_undecodable_blocker_classes_are_named_not_counted
      ; Alcotest.test_case
          "decodable classes still decode"
          `Quick
          test_decodable_blocker_classes_stay_decodable
      ; Alcotest.test_case
          "typed exhaustion reaches runtime_exhausted"
          `Quick
          test_exhaustion_reaches_the_runtime_exhausted_class
      ; Alcotest.test_case
          "provider error without a reason stays provider_runtime_error"
          `Quick
          test_provider_error_without_reason_stays_provider_error
      ] );
    ]
;;
