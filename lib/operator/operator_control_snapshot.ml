module U = Yojson.Safe.Util
include Operator_pending_confirm
include Operator_digest

include Operator_control_context_snapshot

(* Keeper runtime identity fields extracted to
   [Operator_control_snapshot_identity_fields] (godfile decomp). *)
let non_empty_trimmed_string_opt = Operator_control_snapshot_identity_fields.non_empty_trimmed_string_opt
let keeper_runtime_identity_fields = Operator_control_snapshot_identity_fields.keeper_runtime_identity_fields
let degraded_keeper_runtime_identity_fields = Operator_control_snapshot_identity_fields.degraded_keeper_runtime_identity_fields
(* action_result_status + confirmation_state + action_log_entry types,
   stringifiers, and persistence helpers extracted to
   [Operator_control_snapshot_action_log] (godfile decomp). The
   include flows through to [Operator_control] via
   [Operator_control_action] in the existing include chain. *)
include Operator_control_snapshot_action_log

let json_ok = Tool_args.ok_assoc

let get_payload args =
  match U.member "payload" args with
  | `Assoc _ as payload -> payload
  | _ -> `Assoc []
;;

let merge_json_objects left right =
  match left, right with
  | `Assoc left_fields, `Assoc right_fields -> `Assoc (left_fields @ right_fields)
  | `Assoc left_fields, _ -> `Assoc left_fields
  | _, `Assoc right_fields -> `Assoc right_fields
  | _, _ -> `Assoc []
;;

let iso_of_unix = Dashboard_utils.iso_of_unix
(* remote_confirm_ttl_seconds + runtime-status alignment helpers
   extracted to [Operator_control_snapshot_runtime_status] (godfile decomp). *)
let remote_confirm_ttl_seconds = Operator_control_snapshot_runtime_status.remote_confirm_ttl_seconds
let runtime_status_from_live_signal = Operator_control_snapshot_runtime_status.runtime_status_from_live_signal
let health_state_allows_runtime_status_override = Operator_control_snapshot_runtime_status.health_state_allows_runtime_status_override
let align_keeper_runtime_status = Operator_control_snapshot_runtime_status.align_keeper_runtime_status
let remote_client_type_of_context = Operator_control_snapshot_runtime_status.remote_client_type_of_context
let max_turns_override_source = Operator_control_snapshot_runtime_status.max_turns_override_source
let operator_server_profile_json = Operator_control_snapshot_runtime_status.operator_server_profile_json


let recent_messages_json config =
  Coord.get_messages_raw config ~since_seq:0 ~limit:20
  |> List.map Masc_domain.message_to_yojson
  |> fun rows -> `List rows
;;

let merge_tool_name_lists = Operator_control_snapshot_tool_names.merge_tool_name_lists
let tool_names_of_recent_json = Operator_control_snapshot_tool_names.tool_names_of_recent_json
let collect_recent_tool_names = Operator_control_snapshot_tool_names.collect_recent_tool_names
let lightweight_tool_audit_fallback_json = Operator_control_snapshot_tool_audit.lightweight_tool_audit_fallback_json
let recent_tool_names_from_files = Operator_control_snapshot_tool_audit.recent_tool_names_from_files
let keeper_tool_audit_fields = Operator_control_snapshot_tool_audit.keeper_tool_audit_fields
let cached_tool_audit_json = Operator_control_snapshot_tool_audit.cached_tool_audit_json
let _keeper_snapshot_max_concurrency =
  match Sys.getenv_opt "MASC_KEEPER_SNAPSHOT_CONCURRENCY" with
  | Some s ->
    (match int_of_string_opt (String.trim s) with
     | Some n when n >= 1 && n <= 64 -> n
     | _ -> 16)
  | None -> 16
;;

let _keeper_sem = Eio.Semaphore.make _keeper_snapshot_max_concurrency

let compact_keeper_runtime_trust_json = Operator_control_snapshot_trust.compact_keeper_runtime_trust_json
let degraded_keeper_snapshot_row = Operator_control_snapshot_trust.degraded_keeper_snapshot_row
let keepers_json
      ?keeper_names
      ?(include_recent_activity = false)
      ?(lightweight = false)
      config
  =
  let names =
    match keeper_names with
    | Some n -> n
    | None -> Keeper_types.keeper_names config
  in
  (* Parallel keeper I/O with concurrency cap: at most
     _keeper_snapshot_max_concurrency fibers run simultaneously.
     Without this cap, 9+ keepers doing concurrent file I/O + JSON
     construction can cause memory spikes during dashboard refresh. *)
  let n = List.length names in
  let results = Array.make n None in
  let fd_degraded = Keeper_fd_pressure.active () in
  let keeper_sem = if fd_degraded then Eio.Semaphore.make 1 else _keeper_sem in
  Eio.Fiber.all
    (List.mapi
       (fun idx name () ->
          Eio.Switch.run
          @@ fun keeper_sw ->
          (* Two-phase timing so we can distinguish semaphore contention
            from per-keeper I/O cost when dashboard snapshots stall.
            Emits [keepers_json:NAME wait=… work=…] only when either
            half exceeds the same 500ms threshold used by the outer
            [timed] helper, keeping the log quiet on healthy snapshots. *)
          let t_wait_start = Time_compat.now () in
          Eio.Semaphore.acquire keeper_sem;
          let t_work_start = Time_compat.now () in
          let wait_ms = (t_work_start -. t_wait_start) *. 1000.0 in
          Eio.Switch.on_release keeper_sw (fun () ->
            Eio.Semaphore.release keeper_sem;
            let work_ms = (Time_compat.now () -. t_work_start) *. 1000.0 in
            if work_ms > 500.0 || wait_ms > 500.0
            then
              Log.Dashboard.info
                "[keepers_json:%s] wait=%.0fms work=%.0fms"
                name
                wait_ms
                work_ms);
          (* Per-sub-op timing for #8822: attribute ~3100ms snapshot cost.
            Threshold 300ms — lower than outer 500ms for more data. *)
          let dt_meta = ref 0.0 in
          let dt_agent = ref 0.0 in
          let dt_ka = ref 0.0 in
          let dt_audit = ref 0.0 in
          let dt_profile = ref 0.0 in
          let dt_phase = ref 0.0 in
          let dt_trust = ref 0.0 in
          let dt_activity = ref 0.0 in
          let emit_timing_log total_work =
            if total_work > 0.3
            then
              Log.Dashboard.info
                "[keepers_json:%s] sub-op: meta=%.0fms agent=%.0fms ka=%.0fms \
                 audit=%.0fms profile=%.0fms phase=%.0fms trust=%.0fms activity=%.0fms \
                 total=%.0fms"
                name
                (!dt_meta *. 1000.0)
                (!dt_agent *. 1000.0)
                (!dt_ka *. 1000.0)
                (!dt_audit *. 1000.0)
                (!dt_profile *. 1000.0)
                (!dt_phase *. 1000.0)
                (!dt_trust *. 1000.0)
                (!dt_activity *. 1000.0)
                (total_work *. 1000.0)
          in
          results.(idx)
          <- (try
                let t0 = Time_compat.now () in
                match Keeper_types.read_meta config name with
                | Error _ | Ok None -> None
                | Ok (Some meta) ->
                  dt_meta := Time_compat.now () -. t0;
                  if fd_degraded
                  then (
                    emit_timing_log (Time_compat.now () -. t_work_start);
                    Some (degraded_keeper_snapshot_row meta))
                  else if lightweight && meta.paused
                  then (
                    let t_ph = Time_compat.now () in
                    let phase_str =
                      match
                        Keeper_registry.get_phase ~base_path:config.base_path meta.name
                      with
                      | Some p -> `String (Keeper_state_machine.phase_to_string p)
                      | None -> `String "paused"
                    in
                    dt_phase := Time_compat.now () -. t_ph;
                    let runtime_trust =
                      let t_trust = Time_compat.now () in
                      let result =
                        try compact_keeper_runtime_trust_json ~config ~meta with
                        | Eio.Cancel.Cancelled _ as e -> raise e
                        | exn ->
                          Log.Dashboard.warn
                            "operator snapshot trust compact failed for paused keeper \
                             %s: %s"
                            meta.name
                            (Printexc.to_string exn);
                          `Null
                      in
                      dt_trust := Time_compat.now () -. t_trust;
                      result
                    in
                    emit_timing_log (Time_compat.now () -. t_work_start);
                    Some
                      (`Assoc
                          ([ "runtime_class", `String "keeper"
                           ; "pipeline_stage", `String "paused"
                           ; "phase", phase_str
                           ; "name", `String meta.name
                           ; "agent_name", `String meta.agent_name
                           ; "status", `String "paused"
                           ; "paused", `Bool true
                           ; "goal", `String meta.goal
                           ; "short_goal", `String meta.short_goal
                           ; "turn_count", `Int meta.runtime.usage.total_turns
                           ; "updated_at", `String meta.updated_at
                           ; "created_at", `String meta.created_at
                           ]
                           @ keeper_runtime_identity_fields meta
                           @ Keeper_status_bridge.runtime_blocker_fields_json config meta
                           @ Keeper_status_bridge.attention_fields_json config meta
                           @ [ "runtime_trust", runtime_trust ])))
                  else (
                    let t_agent = Time_compat.now () in
                    let agent_json =
                      let cache_key = "kas:" ^ meta.agent_name in
                      Dashboard_cache.get_or_compute cache_key ~ttl:2.0 (fun () ->
                        Keeper_exec_status.parse_agent_status
                          config
                          ~agent_name:meta.agent_name)
                    in
                    dt_agent := Time_compat.now () -. t_agent;
                    let t_ka = Time_compat.now () in
                    let keepalive_running =
                      Keeper_status_bridge.runtime_keepalive_running config meta
                    in
                    let keepalive_started_at =
                      Keeper_status_bridge.runtime_keepalive_started_at config meta
                    in
                    dt_ka := Time_compat.now () -. t_ka;
                    let agent_exists =
                      Safe_ops.json_bool ~default:false "exists" agent_json
                    in
                    let now_ts = Time_compat.now () in
                    let created_ts =
                      Coord_resilience.Time.parse_iso8601_opt meta.created_at
                      |> Option.value ~default:0.0
                    in
                    let last_turn_ago_s =
                      if meta.runtime.usage.last_turn_ts <= 0.0
                      then 0.0
                      else now_ts -. meta.runtime.usage.last_turn_ts
                    in
                    let last_handoff_ago_s =
                      if meta.runtime.last_handoff_ts <= 0.0
                      then 0.0
                      else now_ts -. meta.runtime.last_handoff_ts
                    in
                    let last_compaction_ago_s =
                      if meta.runtime.compaction_rt.last_ts <= 0.0
                      then 0.0
                      else now_ts -. meta.runtime.compaction_rt.last_ts
                    in
                    let last_proactive_ago_s =
                      if meta.runtime.proactive_rt.last_ts <= 0.0
                      then 0.0
                      else now_ts -. meta.runtime.proactive_rt.last_ts
                    in
                    let last_activity_ts =
                      List.fold_left
                        max
                        0.0
                        [ meta.runtime.usage.last_turn_ts
                        ; meta.runtime.proactive_rt.last_ts
                        ; meta.runtime.last_handoff_ts
                        ; meta.runtime.compaction_rt.last_ts
                        ; created_ts
                        ]
                    in
                    let last_activity_ago_s =
                      if last_activity_ts <= 0.0 then 0.0 else now_ts -. last_activity_ts
                    in
                    let diagnostic =
                      Keeper_exec_status.keeper_diagnostic_json
                        ~meta
                        ~agent_status:agent_json
                        ~keepalive_running
                        ~history_items:[]
                        ~now_ts
                      |> Keeper_exec_status.augment_keeper_diagnostic_json
                           ~meta
                           ~keepalive_running
                           ~keepalive_started_at
                           ~now_ts
                    in
                    let t_audit = Time_compat.now () in
                    let audit_json = cached_tool_audit_json ~lightweight config meta in
                    let allowed_tool_names =
                      match U.to_list (U.member "allowed_tool_names" audit_json) with
                      | l ->
                        List.filter_map
                          (function
                            | `String s -> Some s
                            | _ -> None)
                          l
                      | exception U.Type_error _ -> []
                    in
                    let recent_tool_names =
                      match U.to_list (U.member "recent_tool_names" audit_json) with
                      | l ->
                        List.filter_map
                          (function
                            | `String s -> Some s
                            | _ -> None)
                          l
                      | exception U.Type_error _ -> []
                    in
                    let latest_tool_names =
                      match U.to_list (U.member "latest_tool_names" audit_json) with
                      | l ->
                        List.filter_map
                          (function
                            | `String s -> Some s
                            | _ -> None)
                          l
                      | exception U.Type_error _ -> []
                    in
                    let latest_tool_call_count =
                      match
                        U.to_option
                          U.to_int
                          (U.member "latest_tool_call_count" audit_json)
                      with
                      | v -> v
                      | exception U.Type_error _ -> None
                    in
                    let latest_action_source =
                      match
                        U.to_option
                          U.to_string
                          (U.member "latest_action_source" audit_json)
                      with
                      | v -> v
                      | exception U.Type_error _ -> None
                    in
                    let tool_audit_source =
                      match
                        U.to_option U.to_string (U.member "tool_audit_source" audit_json)
                      with
                      | v -> v
                      | exception U.Type_error _ -> None
                    in
                    let tool_audit_at =
                      match
                        U.to_option U.to_string (U.member "tool_audit_at" audit_json)
                      with
                      | v -> v
                      | exception U.Type_error _ -> None
                    in
                    dt_audit := Time_compat.now () -. t_audit;
                    let delivery_surface_view =
                      Keeper_social_model.delivery_surface_view_of_meta meta
                      |> Option.map Keeper_social_model.delivery_surface_to_string
                    in
                    let delivery_surface_view_source =
                      Keeper_social_model.delivery_surface_view_source_of_meta meta
                    in
                    let surface_status =
                      if not agent_exists
                      then "offline"
                      else
                        Keeper_exec_status.keeper_surface_status
                          ~agent_status:agent_json
                          ~diagnostic
                    in
                    let aligned_status =
                      if meta.paused
                      then "paused"
                      else
                        align_keeper_runtime_status
                          ~surface_status
                          ~diagnostic
                          ~agent_status_json:agent_json
                          ~keepalive_running
                    in
                    let t_phase = Time_compat.now () in
                    let registry_phase =
                      Keeper_registry.get_phase ~base_path:config.base_path meta.name
                    in
                    dt_phase := Time_compat.now () -. t_phase;
                    let pipeline_stage =
                      if meta.paused
                      then "paused"
                      else
                        match registry_phase with
                        | Some phase -> Keeper_exec_status.pipeline_stage_of_phase phase
                        | None -> "offline"
                    in
                    let phase_str =
                      if meta.paused
                      then (
                        match registry_phase with
                        | Some p -> `String (Keeper_state_machine.phase_to_string p)
                        | None -> `String "paused")
                      else
                        match registry_phase with
                        | Some p -> `String (Keeper_state_machine.phase_to_string p)
                        | None -> `Null
                    in
                    let context_snapshot =
                      if lightweight
                      then fallback_keeper_context_snapshot meta
                      else keeper_context_snapshot_of_meta config meta
                    in
                    let runtime_trust =
                      let t_trust = Time_compat.now () in
                      let result =
                        try compact_keeper_runtime_trust_json ~config ~meta with
                        | Eio.Cancel.Cancelled _ as e -> raise e
                        | exn ->
                          Log.Dashboard.warn
                            "operator snapshot trust compact failed for keeper %s: %s"
                            meta.name
                            (Printexc.to_string exn);
                          `Null
                      in
                      dt_trust := Time_compat.now () -. t_trust;
                      result
                    in
                    let row =
                      `Assoc
                        ([ "runtime_class", `String "keeper"
                         ; "pipeline_stage", `String pipeline_stage
                         ; "phase", phase_str
                         ; "name", `String meta.name
                         ; "agent_name", `String meta.agent_name
                         ; ( "trace_id"
                           , `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                           )
                         ; "goal", `String meta.goal
                         ; "short_goal", `String meta.short_goal
                         ; "mid_goal", `String meta.mid_goal
                         ; "long_goal", `String meta.long_goal
                         ; "status", `String aligned_status
                         ; "paused", `Bool meta.paused
                         ; "pause_state", `String (if meta.paused then "paused" else "active")
                         ; "agent", agent_json
                         ; "generation", `Int meta.runtime.generation
                         ; "turn_count", `Int meta.runtime.usage.total_turns
                         ; "last_turn_ago_s", `Float last_turn_ago_s
                         ; "last_handoff_ago_s", `Float last_handoff_ago_s
                         ; "last_compaction_ago_s", `Float last_compaction_ago_s
                         ; "last_proactive_ago_s", `Float last_proactive_ago_s
                         ; "last_activity_ago_s", `Float last_activity_ago_s
                         ; "last_model_used", `Null
                         ]
                         @ keeper_runtime_identity_fields meta
                         @ [ "keepalive_running", `Bool keepalive_running
                           ; "next_model_hint", `Null
                           ; ( "active_goal_ids"
                             , `List
                                 (List.map
                                    (fun goal_id -> `String goal_id)
                                    meta.active_goal_ids) )
                           ; ( "last_autonomous_action_at"
                             , if String.trim meta.runtime.last_autonomous_action_at = ""
                               then `Null
                               else `String meta.runtime.last_autonomous_action_at )
                           ; ( "autonomous_action_count"
                             , `Int meta.runtime.autonomous_action_count )
                           ; ( "autonomous_turn_count"
                             , `Int meta.runtime.autonomous_turn_count )
                           ; ( "autonomous_text_turn_count"
                             , `Int meta.runtime.autonomous_text_turn_count )
                           ; ( "autonomous_tool_turn_count"
                             , `Int meta.runtime.autonomous_tool_turn_count )
                           ; ( "board_reactive_turn_count"
                             , `Int meta.runtime.board_reactive_turn_count )
                           ; ( "mention_reactive_turn_count"
                             , `Int meta.runtime.mention_reactive_turn_count )
                           ; "noop_turn_count", `Int meta.runtime.noop_turn_count
                           ; ( "allowed_tool_names"
                             , `List
                                 (List.map
                                    (fun value -> `String value)
                                    allowed_tool_names) )
                           ; ( "latest_tool_names"
                             , `List
                                 (List.map (fun value -> `String value) latest_tool_names)
                             )
                           ; ( "recent_tool_names"
                             , `List
                                 (List.map (fun value -> `String value) recent_tool_names)
                             )
                           ; ( "latest_tool_call_count"
                             , option_to_json
                                 (fun value -> `Int value)
                                 latest_tool_call_count )
                           ; ( "latest_action_source"
                             , string_option_to_json latest_action_source )
                           ; "tool_audit_source", string_option_to_json tool_audit_source
                           ; "tool_audit_at", string_option_to_json tool_audit_at
                           ; ( "last_speech_act"
                             , string_option_to_json
                                 (let value = String.trim meta.runtime.last_speech_act in
                                  if value = "" then None else Some value) )
                           ; ( "delivery_surface_view"
                             , string_option_to_json delivery_surface_view )
                           ; ( "delivery_surface_view_source"
                             , string_option_to_json delivery_surface_view_source )
                           ; ( "last_social_transition_reason"
                             , string_option_to_json
                                 (let value =
                                    String.trim meta.runtime.last_social_transition_reason
                                  in
                                  if value = "" then None else Some value) )
                           ; "proactive_enabled", `Bool meta.proactive.enabled
                           ; "proactive_idle_sec", `Int meta.proactive.idle_sec
                           ; "proactive_cooldown_sec", `Int meta.proactive.cooldown_sec
                           ; ( "turn_budget"
                             , let t_profile = Time_compat.now () in
                               let cache_key = "kpd:" ^ meta.name in
                               let result =
                                 Dashboard_cache.get_or_compute
                                   cache_key
                                   ~ttl:10.0
                                   (fun () ->
                                      let profile =
                                        Keeper_types_profile.load_keeper_profile_defaults
                                          meta.name
                                      in
                                      let env_reactive =
                                        Env_config_keeper.KeeperKeepalive
                                        .oas_max_turns_per_call
                                      in
                                      let env_autonomous =
                                        Env_config_keeper.KeeperKeepalive
                                        .oas_max_turns_per_call_scheduled_autonomous
                                      in
                                      let reactive_effective =
                                        Keeper_types_profile.effective_max_turns_per_call
                                          profile
                                      in
                                      let reactive_source =
                                        max_turns_override_source
                                          profile.max_turns_per_call
                                      in
                                      let autonomous_effective =
                                        Keeper_types_profile
                                        .effective_max_turns_per_call_scheduled_autonomous
                                          profile
                                      in
                                      let autonomous_source =
                                        max_turns_override_source
                                          profile.max_turns_per_call_scheduled_autonomous
                                      in
                                      let raw_override_int = function
                                        | Some n -> `Int n
                                        | None -> `Null
                                      in
                                      let manifest_path_json =
                                        match profile.manifest_path with
                                        | Some p -> `String p
                                        | None -> `Null
                                      in
                                      `Assoc
                                        [ ( "reactive"
                                          , `Assoc
                                              [ "value", `Int reactive_effective
                                              ; "source", `String reactive_source
                                              ; "env_default", `Int env_reactive
                                              ; ( "env_var"
                                                , `String
                                                    "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL" )
                                              ; ( "raw_override"
                                                , raw_override_int
                                                    profile.max_turns_per_call )
                                              ] )
                                        ; ( "scheduled_autonomous"
                                          , `Assoc
                                              [ "value", `Int autonomous_effective
                                              ; "source", `String autonomous_source
                                              ; "env_default", `Int env_autonomous
                                              ; ( "env_var"
                                                , `String
                                                    "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS"
                                                )
                                              ; ( "raw_override"
                                                , raw_override_int
                                                    profile
                                                      .max_turns_per_call_scheduled_autonomous
                                                )
                                              ] )
                                        ; "manifest_path", manifest_path_json
                                        ; ( "clamp_min"
                                          , `Int
                                              Keeper_runtime_resolved
                                              .max_turns_per_call_min )
                                        ; ( "clamp_max"
                                          , `Int
                                              Keeper_runtime_resolved
                                              .max_turns_per_call_max )
                                        ])
                               in
                               dt_profile := Time_compat.now () -. t_profile;
                               result )
                           ; ( "last_proactive_reason"
                             , string_option_to_json
                                 (let value =
                                    String.trim meta.runtime.proactive_rt.last_reason
                                  in
                                  if value = "" then None else Some value) )
                           ; ( "last_proactive_preview"
                             , string_option_to_json
                                 (let value =
                                    String.trim meta.runtime.proactive_rt.last_preview
                                  in
                                  if value = "" then None else Some value) )
                           ; ( "last_blocker"
                             , match meta.runtime.last_blocker with
                               | Some info -> Keeper_types.blocker_info_to_json info
                               | None -> `Null )
                           ; "updated_at", `String meta.updated_at
                           ; "created_at", `String meta.created_at
                           ; ( "recent_activity"
                             , let t_act = Time_compat.now () in
                               let result =
                                 if include_recent_activity
                                 then (
                                   let store =
                                     Keeper_types.keeper_metrics_store config name
                                   in
                                   let lines =
                                     let dated = Dated_jsonl.read_recent_lines store 5 in
                                     if dated <> []
                                     then dated
                                     else (
                                       let metrics_path =
                                         Keeper_types.keeper_metrics_path config name
                                       in
                                       Keeper_memory.read_file_tail_lines
                                         metrics_path
                                         ~max_bytes:8000
                                         ~max_lines:5)
                                   in
                                   `List
                                     (List.filter_map
                                        (fun line ->
                                           try Some (Yojson.Safe.from_string line) with
                                           | Yojson.Json_error _ -> None)
                                        lines))
                                 else `List []
                               in
                               dt_activity := Time_compat.now () -. t_act;
                               result )
                           ]
                         @ keeper_context_snapshot_fields context_snapshot
                         @ Keeper_status_bridge.runtime_blocker_fields_json config meta
                         @ Keeper_status_bridge.attention_fields_json config meta
                         @ [ "runtime_trust", runtime_trust ])
                    in
                    emit_timing_log (Time_compat.now () -. t_work_start);
                    Some row)
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Dashboard.error
                  "keepers_json fiber error (%s): %s"
                  name
                  (Printexc.to_string exn);
                None))
       names);
  let rows = Array.to_list results |> List.filter_map Fun.id in
  `Assoc [ "count", `Int (List.length rows); "items", `List rows ]
;;

let persistent_agents_json = Operator_control_snapshot_persistent_agents.persistent_agents_json

let _snapshot_session_window_seconds () =
  Dashboard_http_helpers.operator_snapshot_session_window_seconds ()
;;

let _snapshot_session_limit () = Dashboard_http_helpers.operator_snapshot_session_limit ()

let _snapshot_recent_completed_limit () =
  Dashboard_http_helpers.operator_snapshot_recent_completed_limit ()
;;

(* sessions_json removed — team session cleanup. Sessions always return []. *)

let room_json = Operator_control_snapshot_room.room_json

(* snapshot_view variant + parser extracted to
   [Operator_control_snapshot_view] (godfile decomp). *)
type snapshot_view = Operator_control_snapshot_view.snapshot_view =
  | Summary
  | Sessions
  | Keepers
  | Messages
  | Full

let snapshot_view_to_string = Operator_control_snapshot_view.snapshot_view_to_string
let valid_snapshot_view_strings = Operator_control_snapshot_view.valid_snapshot_view_strings
let snapshot_view_of_string_opt = Operator_control_snapshot_view.snapshot_view_of_string_opt

(* Snapshot TTL cache with same-key deduplication (singleflight)
   extracted to [Operator_control_snapshot_cache] (godfile decomp).
   The include flows through to [Operator_control] via the existing
   include chain ([Operator_control_action] -> ...). *)
include Operator_control_snapshot_cache
let namespace_scope_cache_segment (_config : Coord_utils.config) = "default"

let snapshot_json
      ?actor
      ?view
      ?(include_messages = true)
      ?(include_keepers = true)
      ?(include_summary_fields = true)
      ?(lightweight_summary = false)
      (ctx : 'a context)
  : Yojson.Safe.t
  =
  let cache_key =
    Printf.sprintf
      "%s|%s|%s|%s|%b|%b|%b|%b"
      ctx.config.base_path
      (namespace_scope_cache_segment ctx.config)
      (Option.value ~default:"" actor)
      (Option.value ~default:"" view)
      include_messages
      include_keepers
      include_summary_fields
      lightweight_summary
  in
  (* Singleflight cache lookup: check for fresh hit, in-flight compute,
     or start a new compute.  Uses Eio.Mutex for safe Hashtbl access.
     Waiters use poll-retry (not Condition.await inside protect:true)
     to stay cancellable — same pattern as Dashboard_cache. *)
  let _max_wait_s = 60.0 in
  let _poll_interval_s = 0.25 in
  let rec cache_lookup ~waited =
    if not (Eio_guard.is_ready ())
    then (
      (* Pre-Eio: no concurrency, compute directly *)
      let now = Time_compat.now () in
      match Hashtbl.find_opt _snapshot_table cache_key with
      | Some (Cached { value; expires_at }) when now < expires_at -> value
      | _ ->
        let result = compute_snapshot () in
        let ts = Time_compat.now () in
        _maybe_evict_snapshot ();
        Hashtbl.replace
          _snapshot_table
          cache_key
          (Cached { value = result; expires_at = ts +. _snapshot_ttl_s });
        result)
    else (
      let action =
        Eio.Mutex.use_rw ~protect:true _snapshot_mu (fun () ->
          match Hashtbl.find_opt _snapshot_table cache_key with
          | Some (Cached { value; expires_at }) when Time_compat.now () < expires_at ->
            `Hit value
          | Some (Computing { stale = Some value; _ }) -> `Hit value
          | Some (Computing { started_at; stuck_warned; _ }) ->
            if waited >= _max_wait_s && not !stuck_warned
            then (
              stuck_warned := true;
              Log.Dashboard.warn
                "[snapshot_json] Computing slot still running for %s \
                 (waited=%.1fs elapsed=%.1fs); keeping singleflight owner"
                cache_key
                waited
                (Time_compat.now () -. started_at));
            `Wait
          | Some (Cached { value; _ }) ->
            let cond = Eio.Condition.create () in
            _maybe_evict_snapshot ();
            Hashtbl.replace
              _snapshot_table
              cache_key
              (Computing
                 { cond
                 ; stale = Some value
                 ; started_at = Time_compat.now ()
                 ; stuck_warned = ref false
                 });
            `Compute cond
          | _ ->
            let cond = Eio.Condition.create () in
            _maybe_evict_snapshot ();
            Hashtbl.replace
              _snapshot_table
              cache_key
              (Computing
                 { cond
                 ; stale = None
                 ; started_at = Time_compat.now ()
                 ; stuck_warned = ref false
                 });
            `Compute cond)
      in
      match action with
      | `Hit value -> value
      | `Wait ->
        (* Another fiber is computing this key — poll-retry outside mutex
           to remain cancellable. *)
        Eio.Time.sleep ctx.clock _poll_interval_s;
        cache_lookup ~waited:(waited +. _poll_interval_s)
      | `Compute cond ->
        (match compute_snapshot () with
         | result ->
           let ts = Time_compat.now () in
           Eio.Mutex.use_rw ~protect:true _snapshot_mu (fun () ->
             (* Only write back if we still own the slot *)
             match Hashtbl.find_opt _snapshot_table cache_key with
             | Some (Computing { cond = c; _ }) when c == cond ->
               _maybe_evict_snapshot ();
               Hashtbl.replace
                 _snapshot_table
                 cache_key
                 (Cached { value = result; expires_at = ts +. _snapshot_ttl_s })
             | Some (Cached _) -> ()
             | Some (Computing _) -> ()
             | None -> ());
           Eio.Condition.broadcast cond;
           result
         | exception exn ->
           let bt = Printexc.get_raw_backtrace () in
           Eio.Mutex.use_rw ~protect:true _snapshot_mu (fun () ->
             match Hashtbl.find_opt _snapshot_table cache_key with
             | Some (Computing { cond = c; _ }) when c == cond ->
               Hashtbl.remove _snapshot_table cache_key
             | Some (Cached _) -> ()
             | Some (Computing _) -> ()
             | None -> ());
           Eio.Condition.broadcast cond;
           Printexc.raise_with_backtrace exn bt))
  and compute_snapshot () =
    let t0 = Time_compat.now () in
    let timing_records = ref [] in
    let timed label f =
      let t_start = Time_compat.now () in
      let result = f () in
      let elapsed = Time_compat.now () -. t_start in
      timing_records := (label, elapsed) :: !timing_records;
      if elapsed > 0.5
      then Log.Dashboard.info "[snapshot_json] %s: %.0fms" label (elapsed *. 1000.0);
      result
    in
    let config = ctx.config in
    let initialized = Coord.is_initialized config in
    ignore (initialized, _snapshot_session_window_seconds (), _snapshot_session_limit ());
    let trace_id = trace_id "ops" in
    let actor_name = normalized_actor ~context_actor:ctx.agent_name actor in
    let view =
      match Option.bind view snapshot_view_of_string_opt with
      | Some view -> view
      | None -> Full
    in
    let include_keepers =
      include_keepers
      &&
      match view with
      | Summary | Keepers | Full -> true
      | Sessions | Messages -> false
    in
    let include_messages =
      include_messages
      &&
      match view with
      | Summary | Messages | Full -> true
      | Sessions | Keepers -> false
    in
    (* Team sessions removed — status_cache and session digests no longer needed. *)
    let status_cache : (string, Yojson.Safe.t) Hashtbl.t = Hashtbl.create 0 in
    let summary_fields =
      timed "summary_fields" (fun () ->
        if
          include_summary_fields
          && initialized
          &&
          match view with
          | Summary | Full -> true
          | Sessions | Keepers | Messages -> false
        then (
          let room_attention =
            build_room_attention_items config |> List.sort compare_attention
          in
          let room_recommendation_items = room_recommendations config in
          [ "attention_summary", summary_of_attention_items room_attention
          ; ( "recommendation_summary"
            , summary_of_recommendations ~actor:actor_name room_recommendation_items )
          ])
        else [])
    in
    let keeper_names =
      if initialized && include_keepers then Keeper_types.keeper_names config else []
    in
    let persistent_keeper_names =
      if initialized && include_keepers
      then Keeper_types.persistent_agent_names config
      else []
    in
    let result =
      `Assoc
        ([ "trace_id", `String trace_id
         ; "server_profile", operator_server_profile_json
         ; "operator_judge_runtime", operator_judge_runtime_json config
         ; "judgment_owner", `String "fallback_read_model"
         ; "authoritative_judgment_available", `Bool false
         ; "admission_queue", Admission_queue.snapshot_json ()
         ; "root", room_json config
         ]
         @ ((* Parallelize independent I/O: sessions, keepers, and persistent_agents. *)
            let empty_section = `Assoc [ "count", `Int 0; "items", `List [] ] in
            let sessions_ref = ref empty_section in
            let keepers_ref = ref empty_section in
            let persistent_ref = ref empty_section in
            Eio.Fiber.all
              [ (fun () ->
                  (* Team sessions removed — always empty *)
                  ignore (lightweight_summary, status_cache);
                  sessions_ref := empty_section)
              ; (fun () ->
                  let keepers_json_value =
                    timed "keepers_json" (fun () ->
                      if initialized && include_keepers
                      then
                        keepers_json
                          ~keeper_names
                          ~lightweight:lightweight_summary
                          ~include_recent_activity:(not lightweight_summary)
                          config
                      else empty_section)
                  in
                  keepers_ref := keepers_json_value;
                  persistent_ref
                  := timed "persistent_agents_json" (fun () ->
                       if initialized && include_keepers
                       then (
                         let keeper_rows =
                           match keepers_json_value with
                           | `Assoc fields ->
                             (match List.assoc_opt "items" fields with
                              | Some (`List rows) -> rows
                              | _ -> [])
                           | _ -> []
                         in
                         persistent_agents_json
                           ~keeper_names:persistent_keeper_names
                           ~keeper_rows
                           config)
                       else empty_section))
              ];
            [ "sessions", !sessions_ref
            ; "keepers", !keepers_ref
            ; "persistent_agents", !persistent_ref
            ])
         @ [ ( "recent_messages"
             , if initialized && include_messages && not lightweight_summary
               then recent_messages_json config
               else `List [] )
           ]
         @ (let confirm_scope =
              timed "pending_confirms" (fun () -> pending_confirm_scope ?actor config)
            in
            [ ( "pending_confirms"
              , `List (List.map pending_confirm_to_yojson confirm_scope.visible_entries) )
            ; ( "pending_confirm_envelope"
              , `Assoc
                  [ ( "items"
                    , `List
                        (List.map pending_confirm_to_yojson confirm_scope.visible_entries)
                    )
                  ; "summary", pending_confirm_summary_json_of_scope confirm_scope
                  ] )
            ; ( "pending_confirm_summary"
              , pending_confirm_summary_json_of_scope confirm_scope )
            ])
         @ [ "available_actions", available_actions_json
           ; ( "recent_actions"
             , if lightweight_summary then `List [] else recent_actions_json config )
           ]
         @ summary_fields)
    in
    let elapsed_total = Time_compat.now () -. t0 in
    if elapsed_total > 1.0
    then (
      Log.Dashboard.info
        "[snapshot_json] total: %.0fms (sessions=%d keepers=%d)"
        (elapsed_total *. 1000.0)
        0
        (List.length keeper_names);
      List.iter
        (fun (label, dt) ->
           if dt > 0.1
           then Log.Dashboard.info "[snapshot_json]   %s: %.0fms" label (dt *. 1000.0))
        (List.rev !timing_records));
    result
  in
  cache_lookup ~waited:0.0
;;
