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
  ; board_interests = [ "MASC runtime" ]
  }
;;

 let test_empty_live_meta_does_not_mask_profile_defaults_as_overrides () =
  init_runtime_default_for_tests ();
  let meta =
    { (make_meta ()) with
      instructions = "";
      mention_targets = [];
      board_interests = [];
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
  [ Recover; Probe; Direct_message ]
  |> List.map (fun path ->
       ( match path with
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
      board_interests = [ "MASC runtime" ];
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
      ; fenced_empty_turn_runtime = None
      }
  in
  match (Keeper_status_bridge.runtime_blocker_surface_of_failure_reason
      ~latest_receipt:(fun () -> Masc.Keeper_execution_receipt.No_receipt)) reason with
  | None -> Alcotest.fail "an exhaustion reason must produce a blocker surface"
  | Some surface ->
    Alcotest.(check string)
      "typed exhaustion is not flattened into provider_runtime_error"
      "runtime_exhausted"
      (Keeper_status_bridge.runtime_blocker_class_to_string surface.Keeper_status_bridge.blocker_class)

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
      ; fenced_empty_turn_runtime = None
      }
  in
  match (Keeper_status_bridge.runtime_blocker_surface_of_failure_reason
      ~latest_receipt:(fun () -> Masc.Keeper_execution_receipt.No_receipt)) reason with
  | None -> Alcotest.fail "a provider error must produce a blocker surface"
  | Some surface ->
    Alcotest.(check string)
      "a provider error without an exhaustion reason keeps its own class"
      "provider_runtime_error"
      (Keeper_status_bridge.runtime_blocker_class_to_string surface.Keeper_status_bridge.blocker_class)

(* The fenced empty assistant turn, end to end through the real write and
   read paths. The write path still holds the typed error, so it marks the
   record; the read path cannot re-derive "empty turn" from the prose
   [detail] (a preview written for logs), so it trusts the marker. No wire
   string is retyped here: the error value is built from constructors, the
   detail is the same preview the failure path applies, and the expected
   sentence is the product wording this test pins. *)
let empty_turn_cause ~scope =
  Keeper_internal_error.Fenced_masc
    (Keeper_internal_error.Accept_rejected
       { scope
       ; model = None
       ; reason_kind = Some Keeper_internal_error.Accept_no_usable_progress
       ; response_shape = Some Keeper_internal_error.Accept_response_empty
       ; stop_reason = None
       ; reason = "empty assistant turn"
       })
;;

let empty_turn_fence
    ?(effect_disposition = Keeper_provider_attempt_effect_core.No_effect_observed)
    ~scope () =
  Keeper_internal_error.Provider_attempt_effect_fenced
    { runtime_id = scope; effect_disposition; cause = empty_turn_cause ~scope }
;;

let test_fenced_empty_turn_is_recorded_with_its_marker () =
  let scope = "openrouter" in
  let fence = empty_turn_fence ~scope () in
  let err = Keeper_internal_error.core_error_of_masc_internal_error fence in
  let raw_error = Agent_core.Error.to_string err in
  let terminal = Keeper_turn_terminal.of_failure ~raw_error err in
  let detail =
    Keeper_types_profile.short_preview
      (match Keeper_internal_error.fenced_attempt_summary fence with
       | Some summary -> summary
       | None -> Alcotest.fail "a fenced attempt must summarize")
  in
  match
    Keeper_unified_turn_types.registry_failure_reason_of_terminal_reason
      ~core_error:err terminal ~raw_error
  with
  | Some (Keeper_registry.Provider_runtime_error record) ->
    Alcotest.(check (option string))
      "the write path marks the typed empty turn"
      (Some scope) record.fenced_empty_turn_runtime;
    Alcotest.(check string)
      "the log-facing preview survives as the detail"
      detail record.detail;
    (match
       Keeper_status_bridge.runtime_blocker_surface_of_failure_reason
         ~latest_receipt:(fun () -> Masc.Keeper_execution_receipt.No_receipt)
         (Keeper_registry.Provider_runtime_error record)
     with
     | None -> Alcotest.fail "a marked empty turn must produce a blocker surface"
     | Some surface ->
       Alcotest.(check string)
         "the provider error keeps its own class"
         "provider_runtime_error"
         (Keeper_status_bridge.runtime_blocker_class_to_string
            surface.Keeper_status_bridge.blocker_class);
       Alcotest.(check string)
         "the human sentence leads"
         (Printf.sprintf
            "Model runtime %s returned an empty assistant turn, so this attempt made no progress; message the keeper again to retry. This runtime does not switch to another runtime automatically."
            scope)
         (Lazy.force surface.Keeper_status_bridge.summary);
       Alcotest.(check (option string))
         "the signature keeps the machine wire"
         (Some (record.code ^ ": " ^ record.detail))
         surface.Keeper_status_bridge.signature)
  | Some _ -> Alcotest.fail "a fenced empty turn must record a provider runtime error"
  | None -> Alcotest.fail "a fenced empty turn must record a failure reason"
;;

(* A fenced failure whose cause is not an empty turn must never earn the
   marker: the marker vouches for emptiness, and the read path cannot check
   it a second time. *)
let test_fenced_non_empty_turn_keeps_no_marker () =
  let scope = "openrouter" in
  let cause =
    Keeper_internal_error.Fenced_masc
      (Keeper_internal_error.Accept_rejected
         { scope
         ; model = None
         ; reason_kind = Some Keeper_internal_error.Accept_predicate_rejected
         ; response_shape = Some Keeper_internal_error.Accept_response_empty
         ; stop_reason = None
         ; reason = "predicate said no"
         })
  in
  Alcotest.(check (option bool))
    "a rejected-but-not-empty cause is not an empty turn"
    (Some false) (Keeper_internal_error.fenced_cause_empty_no_progress cause);
  let err =
    Keeper_internal_error.core_error_of_masc_internal_error
      (Keeper_internal_error.Provider_attempt_effect_fenced
         { runtime_id = scope
         ; effect_disposition =
             Keeper_provider_attempt_effect_core.No_effect_observed
         ; cause })
  in
  let raw_error = Agent_core.Error.to_string err in
  let terminal = Keeper_turn_terminal.of_failure ~raw_error err in
  (match
     Keeper_unified_turn_types.registry_failure_reason_of_terminal_reason
       ~core_error:err terminal ~raw_error
   with
   | Some (Keeper_registry.Provider_runtime_error record) ->
     Alcotest.(check (option string))
       "a non-empty fence is never marked"
       None record.fenced_empty_turn_runtime
   | Some _ | None -> ())
;;

(* The empty-turn sentence says the attempt made no progress and invites a
   retry. When a tool may have run ([Effect_attempted]) or the runtime lost
   sight of effects ([Observation_unavailable]), that would invite a repeat,
   so the same empty cause must keep the fallback reading: no marker and no
   replacement signature. Both fenced constructors share the rule. *)
let test_fenced_empty_turn_with_a_possible_effect_keeps_no_marker () =
  let scope = "openrouter" in
  let label = function
    | Keeper_provider_attempt_effect_core.No_effect_observed -> "no_effect_observed"
    | Keeper_provider_attempt_effect_core.Effect_attempted -> "effect_attempted"
    | Keeper_provider_attempt_effect_core.Observation_unavailable -> "observation_unavailable"
  in
  let correction_lost effect_disposition =
    Keeper_internal_error.Tool_correction_lost
      { runtime_id = scope
      ; effect_disposition
      ; reject_count = 1
      ; cause = empty_turn_cause ~scope
      }
  in
  List.iter
    (fun (kind, effect_disposition, fence) ->
      let name = kind ^ " " ^ label effect_disposition in
      let err = Keeper_internal_error.core_error_of_masc_internal_error fence in
      let raw_error = Agent_core.Error.to_string err in
      let terminal = Keeper_turn_terminal.of_failure ~raw_error err in
      match
        Keeper_unified_turn_types.registry_failure_reason_of_terminal_reason
          ~core_error:err terminal ~raw_error
      with
      | Some (Keeper_registry.Provider_runtime_error record as reason) ->
        Alcotest.(check (option string))
          (name ^ ": no empty-turn marker") None record.fenced_empty_turn_runtime;
        (match
           Keeper_status_bridge.runtime_blocker_surface_of_failure_reason
             ~latest_receipt:(fun () -> Masc.Keeper_execution_receipt.No_receipt)
             reason
         with
         | Some surface ->
           Alcotest.(check (option string))
             (name ^ ": the wire is not replaced") None
             surface.Keeper_status_bridge.signature
         | None -> ())
      | Some _ | None -> ())
    [ ( "fenced", Keeper_provider_attempt_effect_core.Effect_attempted
      , empty_turn_fence ~effect_disposition:Keeper_provider_attempt_effect_core.Effect_attempted ~scope () )
    ; ( "fenced", Keeper_provider_attempt_effect_core.Observation_unavailable
      , empty_turn_fence ~effect_disposition:Keeper_provider_attempt_effect_core.Observation_unavailable ~scope () )
    ; ( "correction_lost", Keeper_provider_attempt_effect_core.Effect_attempted
      , correction_lost Keeper_provider_attempt_effect_core.Effect_attempted )
    ; ( "correction_lost", Keeper_provider_attempt_effect_core.Observation_unavailable
      , correction_lost Keeper_provider_attempt_effect_core.Observation_unavailable )
    ]
;;

(* A turn_failures blocker is a count; the registry rebuilds it from the
   durable streak on boot and the typed cause is gone. The summary reads the
   newest execution receipt instead, so the operator sees what failed. Rows
   go through the receipt serializer into the receipt store, which is the
   path a failed turn writes. *)
let receipt_row ~keeper_name ~outcome ~terminal_reason_code ~error_message ~ended_at
  : Keeper_execution_receipt.t
  =
  { Keeper_execution_receipt.keeper_name
  ; trace_id = "trace-turn-failures"
  ; turn_count = Some 7
  ; agent_core_turn_count = None
  ; current_task_id = None
  ; outcome
  ; terminal_reason_code
  ; response_text_present = false
  ; completion_contract_result = Keeper_execution_receipt.Completion_observation_unknown
  ; actionable_signal = None
  ; tool_surface =
      { Keeper_execution_receipt.turn_lane = Masc.Keeper_agent_tool_surface.Lane_tool_optional }
  ; sandbox_kind = Keeper_types_profile_sandbox.Remote_ssh
  ; sandbox_root = None
  ; network_mode = Keeper_types_profile_sandbox.Network_none
  ; runtime_id = "runtime-1"
  ; runtime_selected_model = None
  ; runtime_attempt_count = 1
  ; runtime_lane_attempt_count = 1
  ; runtime_lane_evidence = None
  ; runtime_fallback_applied = false
  ; runtime_outcome = Keeper_execution_receipt.Runtime_failed
  ; agent_core_internal_runtime_allowed = true
  ; degraded_retry_applied = None
  ; degraded_retry_deferred = None
  ; stop_reason = None
  ; error_kind = None
  ; error_message
  ; started_at = "2026-09-23T00:38:00Z"
  ; ended_at
  ; extra_system_context_digest = None
  ; extra_system_context_injected_size = None
  ; extra_system_context_computed_size = None
  }
;;

let contains haystack needle =
  let n = String.length needle in
  let h = String.length haystack in
  let rec go i = i + n <= h && (String.equal (String.sub haystack i n) needle || go (i + 1)) in
  go 0
;;

let test_turn_failures_summary_names_the_newest_failed_receipt () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  let base_path = Filename.temp_dir "keeper_status_turn_failures_" "" in
  Fun.protect
    ~finally:(fun () ->
      Eio_guard.disable ();
      Fs_compat.remove_tree base_path)
    (fun () ->
      let config = Workspace.default_config base_path in
      let keeper_name = "turn-failures" in
      let store =
        Keeper_types_support.keeper_execution_receipt_store config keeper_name
      in
      let summary () =
        match
          Keeper_status_bridge.runtime_blocker_surface_of_failure_reason
            ~latest_receipt:(fun () ->
              Keeper_execution_receipt.read_latest_receipt config keeper_name)
            (Keeper_registry.Turn_consecutive_failures 2)
        with
        | Some surface ->
          Alcotest.(check string)
            "class" "turn_failures" (Keeper_status_bridge.runtime_blocker_class_to_string surface.Keeper_status_bridge.blocker_class);
          Lazy.force surface.Keeper_status_bridge.summary
        | None -> Alcotest.fail "a turn failure streak must produce a blocker surface"
      in
      let empty = summary () in
      Alcotest.(check bool)
        "without a receipt the summary says no receipt names the cause"
        true
        (contains empty "no execution receipt");
      Dated_jsonl.append
        store
        (Keeper_execution_receipt.to_json
           (receipt_row
              ~keeper_name
              ~outcome:`Error
              ~terminal_reason_code:"api_error_rate_limited"
              ~error_message:(Some "Rate limited: Rate limit reached for requests")
              ~ended_at:"2026-09-23T00:38:12Z"));
      let failed = summary () in
      List.iter
        (fun (label, needle) ->
          Alcotest.(check bool) label true (contains failed needle))
        [ "keeps the streak count", "2 consecutive"
        ; "names the terminal reason", "api_error_rate_limited"
        ; "names the error message", "Rate limited: Rate limit reached for requests"
        ; "names when the failed turn ended", "2026-09-23T00:38:12Z"
        ];
      Dated_jsonl.append
        store
        (Keeper_execution_receipt.to_json
           (receipt_row
              ~keeper_name
              ~outcome:`Ok
              ~terminal_reason_code:"success"
              ~error_message:None
              ~ended_at:"2026-09-23T01:00:00Z"));
      let after_ok = summary () in
      Alcotest.(check bool)
        "a newer non-failed receipt is not presented as the cause"
        false
        (contains after_ok "api_error_rate_limited");
      Alcotest.(check bool)
        "the non-failed newest receipt is named as such"
        true
        (contains after_ok "not a failed turn");
      (* A provider wall-clock timeout ends the turn on the failure path with a
         cancelled receipt; that receipt is this streak's cause. *)
      Dated_jsonl.append
        store
        (Keeper_execution_receipt.to_json
           (receipt_row
              ~keeper_name
              ~outcome:`Cancelled
              ~terminal_reason_code:"api_error_timeout"
              ~error_message:(Some "provider wall-clock timeout")
              ~ended_at:"2026-09-23T01:10:00Z"));
      let after_cancelled = summary () in
      List.iter
        (fun (label, needle) ->
          Alcotest.(check bool) label true (contains after_cancelled needle))
        [ "labels the cancelled turn", "cancelled"
        ; "names the cancelled turn's reason", "api_error_timeout"
        ; "names the cancelled turn's message", "provider wall-clock timeout"
        ])
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
          "typed exhaustion reaches runtime_exhausted"
          `Quick
          test_exhaustion_reaches_the_runtime_exhausted_class
      ; Alcotest.test_case
          "provider error without a reason stays provider_runtime_error"
          `Quick
          test_provider_error_without_reason_stays_provider_error
      ] );
    ( "turn_failures blocker cause"
    , [ Alcotest.test_case
          "summary names the newest failed receipt"
          `Quick
          test_turn_failures_summary_names_the_newest_failed_receipt
      ] );
    ( "fenced empty-turn marker"
    , [ Alcotest.test_case
          "the typed empty turn is recorded with its marker"
          `Quick
          test_fenced_empty_turn_is_recorded_with_its_marker
      ; Alcotest.test_case
          "a non-empty fence keeps no marker"
          `Quick
          test_fenced_non_empty_turn_keeps_no_marker
      ; Alcotest.test_case
          "an empty turn that may have had an effect keeps no marker"
          `Quick
          test_fenced_empty_turn_with_a_possible_effect_keeps_no_marker
      ] );
    ]
;;
