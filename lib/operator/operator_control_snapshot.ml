module U = Yojson.Safe.Util
include Operator_pending_confirm
include Operator_digest

let compute_context_ratio (meta : Keeper_types.keeper_meta) : float option =
  let input_tokens = meta.runtime.usage.last_input_tokens in
  if input_tokens = 0 then None
  else
    let active_model_label = Keeper_exec_status.active_model_label_of_meta meta in
    if active_model_label = "" then None
    else
      let max_ctx = Cascade_runtime.max_context_of_label active_model_label in
      if max_ctx = 0 then None
      else Some (float_of_int input_tokens /. float_of_int max_ctx)

type action_result_status = ActionOk | ActionError

let action_result_status_to_string = function
  | ActionOk -> "ok"
  | ActionError -> "error"

type confirmation_state =
  | Preview
  | Immediate
  | Expired
  | Denied
  | Confirmed

let confirmation_state_to_string = function
  | Preview -> "preview"
  | Immediate -> "immediate"
  | Expired -> "expired"
  | Denied -> "denied"
  | Confirmed -> "confirmed"

type action_log_entry = {
  trace_id : string;
  actor : string;
  remote_session_id : string option;
  remote_client_type : string;
  action_type : string;
  target_type : string;
  target_id : string option;
  delegated_tool : string;
  confirmation_state : confirmation_state;
  result_status : action_result_status;
  latency_ms : int;
  created_at : string;
}

let json_ok fields =
  `Assoc (("status", `String "ok") :: fields)

let get_payload args =
  match U.member "payload" args with
  | `Assoc _ as payload -> payload
  | _ -> `Assoc []

let merge_json_objects left right =
  match (left, right) with
  | `Assoc left_fields, `Assoc right_fields -> `Assoc (left_fields @ right_fields)
  | `Assoc left_fields, _ -> `Assoc left_fields
  | _, `Assoc right_fields -> `Assoc right_fields
  | _, _ -> `Assoc []

let action_log_path config =
  Filename.concat (operator_dir config) "action_log.jsonl"

let remote_confirm_ttl_seconds = 900.0

let iso_of_unix = Dashboard_utils.iso_of_unix

let runtime_status_from_live_signal (agent_status_json : Yojson.Safe.t) =
  let runtime_status =
    match Keeper_exec_status.agent_status_text agent_status_json with
    | ("active" | "busy" | "listening" | "idle") as status -> Some status
    | _ -> None
  in
  let has_live_signal =
    Keeper_exec_status.agent_runtime_has_live_signal agent_status_json
  in
  let is_zombie =
    Safe_ops.json_bool ~default:false "is_zombie" agent_status_json
  in
  match (runtime_status, has_live_signal, is_zombie) with
  | Some status, true, false -> Some status
  | _ -> None

let health_state_allows_runtime_status_override (diagnostic : Yojson.Safe.t) =
  let kh =
    Safe_ops.json_string ~default:"offline" "health_state" diagnostic
    |> Keeper_exec_status.keeper_health_of_string
  in
  match kh with
  | Keeper_types.KH_stale | KH_degraded | KH_zombie | KH_dead -> false
  | KH_healthy | KH_idle | KH_offline -> true

let align_keeper_runtime_status
    ~(surface_status : string)
    ~(diagnostic : Yojson.Safe.t)
    ~(agent_status_json : Yojson.Safe.t)
    ~(keepalive_running : bool) : string =
  if not keepalive_running then
    surface_status
  else
    let normalized_surface =
      String.lowercase_ascii (String.trim surface_status)
    in
    let runtime_status =
      if health_state_allows_runtime_status_override diagnostic then
        runtime_status_from_live_signal agent_status_json
      else None
    in
    match (normalized_surface, runtime_status) with
    | ("inactive" | "offline"), Some status -> status
    | _ -> surface_status

let remote_client_type_of_context (ctx : 'a context) =
  match ctx.mcp_session_id with
  | Some _ -> "mcp_remote"
  | None -> "local_api"

let operator_server_profile_json =
  `Assoc
    [
      ("name", `String "operator_remote_v1");
      ("transport", `String "mcp_streamable_http");
      ("auth", `String "bearer_token");
      ("confirm_ttl_seconds", `Float remote_confirm_ttl_seconds);
      ("curated_tool_count", `Int 4);
    ]

let action_log_entry_to_yojson (entry : action_log_entry) =
  `Assoc
    [
      ("trace_id", `String entry.trace_id);
      ("actor", `String entry.actor);
      ("remote_session_id", string_option_to_json entry.remote_session_id);
      ("remote_client_type", `String entry.remote_client_type);
      ("action_type", `String entry.action_type);
      ("target_type", `String entry.target_type);
      ("target_id", string_option_to_json entry.target_id);
      ("delegated_tool", `String entry.delegated_tool);
      ("confirmation_state", `String (confirmation_state_to_string entry.confirmation_state));
      ("result_status", `String (action_result_status_to_string entry.result_status));
      ("latency_ms", `Int entry.latency_ms);
      ("created_at", `String entry.created_at);
    ]

let append_action_log config (entry : action_log_entry) =
  Coord_utils.mkdir_p (operator_dir config);
  Fs_compat.append_jsonl (action_log_path config) (action_log_entry_to_yojson entry)

let recent_actions_json config =
  let path = action_log_path config in
  if not (Sys.file_exists path) then
    `List []
  else
    let all = Fs_compat.load_jsonl path in
    let len = List.length all in
    let tail =
      if len <= 20 then all
      else
        all |> List.to_seq |> Seq.drop (len - 20) |> List.of_seq
    in
    `List tail

let recent_messages_json config =
  Coord.get_messages_raw config ~since_seq:0 ~limit:20
  |> List.map Types.message_to_yojson
  |> fun rows -> `List rows

let merge_tool_name_lists primary secondary =
  let seen = Hashtbl.create 16 in
  let add acc raw_name =
    let name = String.trim raw_name in
    if name = "" || Hashtbl.mem seen name then acc
    else (
      Hashtbl.replace seen name ();
      name :: acc)
  in
  List.rev
    (List.fold_left add []
       (List.concat [ primary; secondary ]))

let tool_names_of_recent_json (json : Yojson.Safe.t) =
  let tools_used =
    match U.member "tools_used" json with
    | `List items ->
        List.filter_map
          (function
            | `String value ->
                let trimmed = String.trim value in
                if trimmed = "" then None else Some trimmed
            | _ -> None)
          items
    | _ -> []
  in
  let single_tool =
    match U.member "tool" json with
    | `String value ->
        let trimmed = String.trim value in
        if trimmed = "" then [] else [ trimmed ]
    | _ -> []
  in
  merge_tool_name_lists single_tool tools_used

let collect_recent_tool_names ?(limit = 8) (lines : string list) =
  let ordered = List.rev lines in
  let rec loop acc remaining = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | line :: rest -> (
        try
          let json = Yojson.Safe.from_string line in
          let tools = tool_names_of_recent_json json in
          let merged = merge_tool_name_lists (List.rev acc) tools in
          let capped =
            if List.length merged <= limit then merged
            else List.filteri (fun idx _ -> idx < limit) merged
          in
          loop (List.rev capped) (limit - List.length capped) rest
        with Yojson.Json_error _ ->
          loop acc remaining rest)
  in
  loop [] limit ordered

let recent_tool_names_from_files config keeper_name =
  let decision_lines =
    let path = Keeper_types.keeper_decision_log_path config keeper_name in
    if Fs_compat.file_exists path then
      Keeper_memory.read_file_tail_lines path ~max_bytes:120000 ~max_lines:120
    else []
  in
  let metrics_lines =
    let store = Keeper_types.keeper_metrics_store config keeper_name in
    let dated = Dated_jsonl.read_recent_lines store 120 in
    if dated <> [] then dated
    else
      let path = Keeper_types.keeper_metrics_path config keeper_name in
      Keeper_memory.read_file_tail_lines path ~max_bytes:120000 ~max_lines:120
  in
  merge_tool_name_lists
    (collect_recent_tool_names decision_lines)
    (collect_recent_tool_names metrics_lines)

let keeper_tool_audit_fields ?(include_allowed_tools = true) config
    (meta : Keeper_types.keeper_meta) =
  let fallback_allowed =
    if include_allowed_tools then Keeper_exec_tools.keeper_allowed_tool_names meta
    else []
  in
  let recent_tool_names = recent_tool_names_from_files config meta.name in
  let last_autonomous = String.trim meta.runtime.last_autonomous_action_at in
  let fallback_snapshot =
    match
      Keeper_exec_status_metrics.latest_tool_audit_snapshot_from_files config
        ~keeper_name:meta.name
    with
    | Some snapshot ->
        {
          snapshot with
          tool_audit_at =
            (match snapshot.tool_audit_source, snapshot.tool_audit_at with
             | Some _, None when last_autonomous <> "" -> Some last_autonomous
             | Some _, None -> Some meta.updated_at
             | _ -> snapshot.tool_audit_at);
        }
    | None ->
        let has_runtime_activity =
          last_autonomous <> ""
          || meta.runtime.autonomous_turn_count > 0
          || meta.runtime.autonomous_action_count > 0
        in
        {
          Keeper_exec_status_metrics.empty_tool_audit_snapshot with
          latest_tool_call_count =
            (if has_runtime_activity then Some 0 else None);
          tool_audit_source =
            (if has_runtime_activity then Some "keeper_runtime_meta" else None);
          tool_audit_at =
            (if last_autonomous <> "" then Some last_autonomous
             else if has_runtime_activity then Some meta.updated_at
             else None);
        }
  in
  match A2a_tools.latest_heartbeat_task meta.agent_name,
        A2a_tools.latest_heartbeat_result meta.agent_name with
  | Some task, Some result ->
      if task.seq > result.seq then
        ( task.allowed_tools,
          recent_tool_names,
          result.tool_names,
          Some result.tool_call_count,
          fallback_snapshot.latest_action_source,
          Some "heartbeat_task_pending_result",
          Some task.created_at )
      else
        ( task.allowed_tools,
          merge_tool_name_lists result.tool_names recent_tool_names,
          result.tool_names,
          Some result.tool_call_count,
          fallback_snapshot.latest_action_source,
          Some "heartbeat_result",
          Some result.updated_at )
  | Some task, None ->
      ( task.allowed_tools,
        recent_tool_names,
        [],
        None,
        fallback_snapshot.latest_action_source,
        Some "heartbeat_task",
        Some task.created_at )
  | None, Some result ->
      ( fallback_allowed,
        merge_tool_name_lists result.tool_names recent_tool_names,
        result.tool_names,
        Some result.tool_call_count,
        fallback_snapshot.latest_action_source,
        Some "heartbeat_result",
        Some result.updated_at )
  | None, None ->
      ( fallback_allowed,
        recent_tool_names,
        fallback_snapshot.latest_tool_names,
        fallback_snapshot.latest_tool_call_count,
        fallback_snapshot.latest_action_source,
        fallback_snapshot.tool_audit_source,
        fallback_snapshot.tool_audit_at )

(* Concurrency cap for parallel keeper snapshot fibers.
   Originally 4 to guard against memory bursts when many keepers are
   processed simultaneously.  Live measurement via #8829 over 48 samples
   showed this cap was the dominant cost, not the per-keeper I/O:

       wait avg=1334ms max=4424ms   (queued on semaphore)
       work avg=604ms  max=3088ms   (meta/agent/profile I/O + JSON)
       ratio wait/work = 2.21x

   Raising to 16 matches the current fleet size so no fiber queues on
   the semaphore in the common case.  The original memory concern was
   written when keepers were a new surface; modern machines absorb the
   per-fiber JSON construction (~50 fields × 16 keepers ≈ a few MB)
   without visible pressure.  Env-overridable via
   [MASC_KEEPER_SNAPSHOT_CONCURRENCY] for operators on tight memory
   envelopes (e.g. CI runners) who still want the old behaviour. *)
let _keeper_snapshot_max_concurrency =
  match Sys.getenv_opt "MASC_KEEPER_SNAPSHOT_CONCURRENCY" with
  | Some s ->
      (match int_of_string_opt (String.trim s) with
       | Some n when n >= 1 && n <= 64 -> n
       | _ -> 16)
  | None -> 16

let _keeper_sem = Eio.Semaphore.make _keeper_snapshot_max_concurrency

let keepers_json ?keeper_names ?(include_recent_activity = false)
    ?(lightweight = false) config =
  let names = match keeper_names with
    | Some n -> n
    | None -> Keeper_types.keeper_names config
  in
  (* Parallel keeper I/O with concurrency cap: at most
     _keeper_snapshot_max_concurrency fibers run simultaneously.
     Without this cap, 9+ keepers doing concurrent file I/O + JSON
     construction can cause memory spikes during dashboard refresh. *)
  let n = List.length names in
  let results = Array.make n None in
  Eio.Fiber.all
    (List.mapi
       (fun idx name () ->
         (* Two-phase timing so we can distinguish semaphore contention
            from per-keeper I/O cost when dashboard snapshots stall.
            Emits [keepers_json:NAME wait=… work=…] only when either
            half exceeds the same 500ms threshold used by the outer
            [timed] helper, keeping the log quiet on healthy snapshots. *)
         let t_wait_start = Time_compat.now () in
         Eio.Semaphore.acquire _keeper_sem;
         let t_work_start = Time_compat.now () in
         let wait_ms = (t_work_start -. t_wait_start) *. 1000.0 in
         Fun.protect
           ~finally:(fun () ->
             Eio.Semaphore.release _keeper_sem;
             let work_ms = (Time_compat.now () -. t_work_start) *. 1000.0 in
             if work_ms > 500.0 || wait_ms > 500.0 then
               Log.Dashboard.info
                 "[keepers_json:%s] wait=%.0fms work=%.0fms" name wait_ms
                 work_ms)
           (fun () ->
         results.(idx) <-
           (try
             match Keeper_types.read_meta config name with
             | Error _ | Ok None -> None
             | Ok (Some meta) when lightweight && meta.paused ->
                 let phase_str =
                   match Keeper_registry.get_phase ~base_path:config.base_path meta.name with
                   | Some p -> `String (Keeper_state_machine.phase_to_string p)
                   | None -> `String "paused"
                 in
                 Some
                   (`Assoc
                     [
                       ("runtime_class", `String "keeper");
                       ("pipeline_stage", `String "paused");
                       ("phase", phase_str);
                       ("name", `String meta.name);
                       ("agent_name", `String meta.agent_name);
                       ("status", `String "paused");
                       ("paused", `Bool true);
                       ("goal", `String meta.goal);
                       ("short_goal", `String meta.short_goal);
                       ("turn_count", `Int meta.runtime.usage.total_turns);
                       ("updated_at", `String meta.updated_at);
                       ("created_at", `String meta.created_at);
                     ])
             | Ok (Some meta) ->
                 let agent_json =
                   Keeper_exec_status.parse_agent_status config ~agent_name:meta.agent_name
                 in
                 let keepalive_running =
                   Keeper_status_bridge.runtime_keepalive_running config meta
                 in
                 let agent_exists =
                   Safe_ops.json_bool ~default:false "exists" agent_json
                 in
                 let now_ts = Time_compat.now () in
                 let keepalive_started_at =
                   Keeper_status_bridge.runtime_keepalive_started_at config meta
                 in
                 let created_ts =
                   Resilience.Time.parse_iso8601_opt meta.created_at
                   |> Option.value ~default:0.0
                 in
                 let last_turn_ago_s =
                   if meta.runtime.usage.last_turn_ts <= 0.0 then 0.0
                   else now_ts -. meta.runtime.usage.last_turn_ts
                 in
                 let last_handoff_ago_s =
                   if meta.runtime.last_handoff_ts <= 0.0 then 0.0
                   else now_ts -. meta.runtime.last_handoff_ts
                 in
                 let last_compaction_ago_s =
                   if meta.runtime.compaction_rt.last_ts <= 0.0 then 0.0
                   else now_ts -. meta.runtime.compaction_rt.last_ts
                 in
                 let last_proactive_ago_s =
                   if meta.runtime.proactive_rt.last_ts <= 0.0 then 0.0
                   else now_ts -. meta.runtime.proactive_rt.last_ts
                 in
                 let last_activity_ts =
                   List.fold_left max 0.0
                     [
                       meta.runtime.usage.last_turn_ts;
                       meta.runtime.proactive_rt.last_ts;
                       meta.runtime.last_handoff_ts;
                       meta.runtime.compaction_rt.last_ts;
                       created_ts;
                     ]
                 in
                 let last_activity_ago_s =
                   if last_activity_ts <= 0.0 then 0.0
                   else now_ts -. last_activity_ts
                 in
                 let diagnostic =
                   Keeper_exec_status.keeper_diagnostic_json ~meta
                     ~agent_status:agent_json ~keepalive_running ~history_items:[]
                     ~now_ts
                   |> Keeper_exec_status.augment_keeper_diagnostic_json
                        ~meta ~keepalive_running ~keepalive_started_at ~now_ts
                 in
                 let allowed_tool_names, recent_tool_names, latest_tool_names,
                     latest_tool_call_count, latest_action_source,
                     tool_audit_source, tool_audit_at =
                   if lightweight then
                     let _, recent_tool_names, latest_tool_names,
                         latest_tool_call_count, latest_action_source,
                         tool_audit_source, tool_audit_at =
                       keeper_tool_audit_fields ~include_allowed_tools:false
                         config meta
                     in
                     ( [],
                       recent_tool_names,
                       latest_tool_names,
                       latest_tool_call_count,
                       latest_action_source,
                       tool_audit_source,
                       tool_audit_at )
                   else keeper_tool_audit_fields config meta
                 in
                 let delivery_surface_view =
                   Keeper_social_model.delivery_surface_view_of_meta meta
                   |> Option.map Keeper_social_model.delivery_surface_to_string
                 in
                 let delivery_surface_view_source =
                   Keeper_social_model.delivery_surface_view_source_of_meta meta
                 in
                 let surface_status =
                   if not agent_exists then "offline"
                   else Keeper_exec_status.keeper_surface_status ~agent_status:agent_json ~diagnostic
                 in
                 let aligned_status =
                   align_keeper_runtime_status ~surface_status
                     ~diagnostic
                     ~agent_status_json:agent_json ~keepalive_running
                 in
                 let registry_phase =
                   Keeper_registry.get_phase ~base_path:config.base_path meta.name
                 in
                 let pipeline_stage =
                   match registry_phase with
                   | Some phase -> Keeper_exec_status.pipeline_stage_of_phase phase
                   | None -> "offline"
                 in
                 let phase_str =
                   match registry_phase with
                   | Some p -> `String (Keeper_state_machine.phase_to_string p)
                   | None -> `Null
                 in
                 Some
                   (`Assoc
                     ([
                       ("runtime_class", `String "keeper");
                       ("pipeline_stage", `String pipeline_stage);
                       ("phase", phase_str);
                       ("name", `String meta.name);
                       ("agent_name", `String meta.agent_name);
                       ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
                       ("goal", `String meta.goal);
                       ("short_goal", `String meta.short_goal);
                       ("mid_goal", `String meta.mid_goal);
                       ("long_goal", `String meta.long_goal);
                       ("status", `String aligned_status);
                       ("agent", agent_json);
                       ("generation", `Int meta.runtime.generation);
                       ("turn_count", `Int meta.runtime.usage.total_turns);
                       ("context_ratio",
                         (match compute_context_ratio meta with
                          | Some r -> `Float r
                          | None -> `Null));
                       ("context_tokens", `Int meta.runtime.usage.last_total_tokens);
                       ("last_turn_ago_s", `Float last_turn_ago_s);
                       ("last_handoff_ago_s", `Float last_handoff_ago_s);
                       ("last_compaction_ago_s", `Float last_compaction_ago_s);
                       ("last_proactive_ago_s", `Float last_proactive_ago_s);
                       ("last_activity_ago_s", `Float last_activity_ago_s);
                       ("last_model_used", `String meta.runtime.usage.last_model_used);
                       ("active_model", `String (Keeper_exec_status.active_model_of_meta meta));
                       ("keepalive_running", `Bool keepalive_running);
                       ( "next_model_hint",
                         string_option_to_json (Keeper_exec_status.next_model_hint_of_meta meta)
                       );
                       ( "active_goal_ids",
                         `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids)
                       );
                       ( "last_autonomous_action_at",
                         if String.trim meta.runtime.last_autonomous_action_at = "" then `Null
                         else `String meta.runtime.last_autonomous_action_at );
                       ("autonomous_action_count", `Int meta.runtime.autonomous_action_count);
                       ("autonomous_turn_count", `Int meta.runtime.autonomous_turn_count);
                       ("autonomous_text_turn_count", `Int meta.runtime.autonomous_text_turn_count);
                       ("autonomous_tool_turn_count", `Int meta.runtime.autonomous_tool_turn_count);
                       ("board_reactive_turn_count", `Int meta.runtime.board_reactive_turn_count);
                       ("mention_reactive_turn_count", `Int meta.runtime.mention_reactive_turn_count);
                       ("noop_turn_count", `Int meta.runtime.noop_turn_count);
                       ("allowed_tool_names", `List (List.map (fun value -> `String value) allowed_tool_names));
                       ("latest_tool_names", `List (List.map (fun value -> `String value) latest_tool_names));
                       ("recent_tool_names", `List (List.map (fun value -> `String value) recent_tool_names));
                       ("latest_tool_call_count", option_to_json (fun value -> `Int value) latest_tool_call_count);
                       ("latest_action_source", string_option_to_json latest_action_source);
                       ("tool_audit_source", string_option_to_json tool_audit_source);
                       ("tool_audit_at", string_option_to_json tool_audit_at);
                       ( "last_speech_act",
                         string_option_to_json
                           (let value = String.trim meta.runtime.last_speech_act in
                            if value = "" then None else Some value) );
                       ("delivery_surface_view", string_option_to_json delivery_surface_view);
                       ( "delivery_surface_view_source",
                         string_option_to_json delivery_surface_view_source );
                       ( "last_social_transition_reason",
                         string_option_to_json
                           (let value =
                              String.trim meta.runtime.last_social_transition_reason
                            in
                            if value = "" then None else Some value) );
                       ("proactive_enabled", `Bool meta.proactive.enabled);
                       ("proactive_idle_sec", `Int meta.proactive.idle_sec);
                       ("proactive_cooldown_sec", `Int meta.proactive.cooldown_sec);
                       ("turn_budget",
                         (let profile =
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
                          let classify_source = function
                            | Some n when n >= 1 && n <= 50 -> "override"
                            | Some _ -> "override_invalid"
                            | None -> "env"
                          in
                          let reactive_source =
                            classify_source profile.max_turns_per_call
                          in
                          let autonomous_effective =
                            Keeper_types_profile
                            .effective_max_turns_per_call_scheduled_autonomous
                              profile
                          in
                          let autonomous_source =
                            classify_source
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
                            [
                              ( "reactive",
                                `Assoc
                                  [
                                    ("value", `Int reactive_effective);
                                    ("source", `String reactive_source);
                                    ("env_default", `Int env_reactive);
                                    ( "env_var",
                                      `String
                                        "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL" );
                                    ( "raw_override",
                                      raw_override_int
                                        profile.max_turns_per_call );
                                  ] );
                              ( "scheduled_autonomous",
                                `Assoc
                                  [
                                    ("value", `Int autonomous_effective);
                                    ("source", `String autonomous_source);
                                    ("env_default", `Int env_autonomous);
                                    ( "env_var",
                                      `String
                                        "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS"
                                    );
                                    ( "raw_override",
                                      raw_override_int
                                        profile
                                          .max_turns_per_call_scheduled_autonomous );
                                  ] );
                              ("manifest_path", manifest_path_json);
                              ("clamp_min", `Int 1);
                              ("clamp_max", `Int 50);
                            ]));
                       ("last_proactive_reason",
                         string_option_to_json
                           (let value = String.trim meta.runtime.proactive_rt.last_reason in
                            if value = "" then None else Some value));
                       ("last_proactive_preview",
                         string_option_to_json
                           (let value = String.trim meta.runtime.proactive_rt.last_preview in
                            if value = "" then None else Some value));
                       ("last_blocker",
                         string_option_to_json
                           (let value = String.trim meta.runtime.last_blocker in
                            if value = "" then None else Some value));
                       ("updated_at", `String meta.updated_at);
                       ("created_at", `String meta.created_at);
                       ("recent_activity",
                         if include_recent_activity then
                           let store = Keeper_types.keeper_metrics_store config name in
                           let lines =
                             let dated = Dated_jsonl.read_recent_lines store 5 in
                             if dated <> [] then dated
                             else
                               let metrics_path = Keeper_types.keeper_metrics_path config name in
                               Keeper_memory.read_file_tail_lines metrics_path
                                 ~max_bytes:8000 ~max_lines:5
                           in
                           `List (List.filter_map (fun line ->
                             try Some (Yojson.Safe.from_string line)
                             with Yojson.Json_error _ -> None) lines)
                         else
                           `List []);
                     ]
                     @ Keeper_status_bridge.runtime_blocker_fields_json config meta))
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             Log.Dashboard.error "keepers_json fiber error (%s): %s"
               name (Printexc.to_string exn);
             None)))
       names);
  let rows = Array.to_list results |> List.filter_map Fun.id in
  `Assoc [ ("count", `Int (List.length rows)); ("items", `List rows) ]

let persistent_agents_json ?keeper_names ?keeper_rows config =
  let rows_from_keeper_rows names rows =
    let wanted = List.sort_uniq String.compare names in
    let wanted_tbl = Hashtbl.create (List.length wanted) in
    List.iter (fun name -> Hashtbl.replace wanted_tbl name ()) wanted;
    rows
    |> List.filter_map (function
         | `Assoc fields -> (
             match List.assoc_opt "name" fields with
             | Some (`String name) when Hashtbl.mem wanted_tbl name ->
                 let field_or_null key =
                   match List.assoc_opt key fields with
                   | Some value -> value
                   | None -> `Null
                 in
                 Some
                   (`Assoc
                     [
                       ("runtime_class", `String "keeper");
                       ("name", field_or_null "name");
                       ("agent_name", field_or_null "agent_name");
                       ("trace_id", field_or_null "trace_id");
                       ("goal", field_or_null "goal");
                       ("short_goal", field_or_null "short_goal");
                       ("mid_goal", field_or_null "mid_goal");
                       ("long_goal", field_or_null "long_goal");
                       ("status", field_or_null "status");
                       ("generation", field_or_null "generation");
                       ("turn_count", field_or_null "turn_count");
                       ("context_ratio", field_or_null "context_ratio");
                       ("context_tokens", field_or_null "context_tokens");
                       ("last_model_used", field_or_null "last_model_used");
                       ("active_model", field_or_null "active_model");
                       ("next_model_hint", field_or_null "next_model_hint");
                       ("active_goal_ids", field_or_null "active_goal_ids");
                       ("last_autonomous_action_at", field_or_null "last_autonomous_action_at");
                       ("autonomous_action_count", field_or_null "autonomous_action_count");
                       ("updated_at", field_or_null "updated_at");
                       ("created_at", field_or_null "created_at");
                     ])
             | _ -> None)
         | _ -> None)
  in
  let rows =
    match keeper_rows with
    | Some rows ->
        let names =
          match keeper_names with
          | Some names -> names
          | None -> Keeper_types.persistent_agent_names config
        in
        rows_from_keeper_rows names rows
    | None ->
        let names =
          match keeper_names with
          | Some names -> names
          | None -> Keeper_types.persistent_agent_names config
        in
        List.filter_map
          (fun name ->
            match Keeper_types.read_meta config name with
            | Error _ | Ok None -> None
            | Ok (Some meta) ->
                let agent_json =
                  Keeper_exec_status.parse_agent_status config ~agent_name:meta.agent_name
                in
                let agent_status =
                  match agent_json with
                  | `Assoc _ -> (
                      match agent_json |> U.member "status" with
                      | `String status -> status
                      | _ -> "unknown")
                  | _ -> "unknown"
                in
                Some
                  (`Assoc
                    [
                      ("runtime_class", `String "keeper");
                      ("name", `String meta.name);
                      ("agent_name", `String meta.agent_name);
                      ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
                      ("goal", `String meta.goal);
                      ("short_goal", `String meta.short_goal);
                      ("mid_goal", `String meta.mid_goal);
                      ("long_goal", `String meta.long_goal);
                      ("status", `String agent_status);
                      ("generation", `Int meta.runtime.generation);
                      ("turn_count", `Int meta.runtime.usage.total_turns);
                      ("context_ratio",
                        (match compute_context_ratio meta with
                         | Some r -> `Float r
                         | None -> `Null));
                      ("context_tokens", `Int meta.runtime.usage.last_total_tokens);
                      ("last_model_used", `String meta.runtime.usage.last_model_used);
                      ("active_model", `String (Keeper_exec_status.active_model_of_meta meta));
                      ("next_model_hint", string_option_to_json (Keeper_exec_status.next_model_hint_of_meta meta));
                      ("active_goal_ids", `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids));
                      ("last_autonomous_action_at",
                        if String.trim meta.runtime.last_autonomous_action_at = "" then `Null else `String meta.runtime.last_autonomous_action_at);
                      ("autonomous_action_count", `Int meta.runtime.autonomous_action_count);
                      ("updated_at", `String meta.updated_at);
                      ("created_at", `String meta.created_at);
                    ]))
          names
  in
  `Assoc [ ("count", `Int (List.length rows)); ("items", `List rows) ]

let _snapshot_session_window_seconds () =
  Dashboard_http_helpers.operator_snapshot_session_window_seconds ()

let _snapshot_session_limit () =
  Dashboard_http_helpers.operator_snapshot_session_limit ()

let _snapshot_recent_completed_limit () =
  Dashboard_http_helpers.operator_snapshot_recent_completed_limit ()

(* sessions_json removed — team session cleanup. Sessions always return []. *)

let room_json config =
  let initialized = Coord.is_initialized config in
  if not initialized then
    `Assoc
      [
        ("initialized", `Bool false);
        ("project", `String (Filename.basename config.base_path));
      ]
  else
    let state = Coord.read_state config in
    let tempo = Tempo.get_tempo config in
    let tasks = Coord.get_tasks_raw config in
    let agents = Coord.get_agents_raw config in
    `Assoc
      [
        ("initialized", `Bool true);
        ("cluster", `String (Env_config_core.cluster_name ()));
        ("project", `String state.project);
        ("paused", `Bool state.paused);
        ("pause_reason", string_option_to_json state.pause_reason);
        ("paused_by", string_option_to_json state.paused_by);
        ("paused_at", string_option_to_json state.paused_at);
        ("tempo_interval_s", `Float tempo.current_interval_s);
        ("agent_count", `Int (List.length agents));
        ("task_count", `Int (List.length tasks));
        ("message_seq", `Int state.message_seq);
      ]

type snapshot_view =
  | Summary
  | Sessions
  | Keepers
  | Messages
  | Full

(* Issue #8471: Variant SSOT for [snapshot_view]. Adding a constructor
   forces [snapshot_view_to_string] exhaustiveness AND extends
   [valid_snapshot_view_strings]; the schema in [tool_operator.ml]
   derives its enum from this list, so a new constructor flows
   through automatically instead of silently dropping (as [Sessions]
   did before this fix). *)
let snapshot_view_to_string = function
  | Summary -> "summary"
  | Sessions -> "sessions"
  | Keepers -> "keepers"
  | Messages -> "messages"
  | Full -> "full"

let all_snapshot_views = [ Summary; Sessions; Keepers; Messages; Full ]

let valid_snapshot_view_strings =
  List.map snapshot_view_to_string all_snapshot_views

(* Sound partial parser — Some for canonical strings, None otherwise.
   [parse_snapshot_view] below intentionally falls back to [Full] for
   tool/HTTP back-compat; this opt variant exists for callers that
   want to distinguish unknown input. *)
let snapshot_view_of_string_opt raw =
  match String.trim raw |> String.lowercase_ascii with
  | "summary" -> Some Summary
  | "sessions" -> Some Sessions
  | "keepers" -> Some Keepers
  | "messages" -> Some Messages
  | "full" -> Some Full
  | _ -> None

let parse_snapshot_view = function
  | Some raw -> (
      match snapshot_view_of_string_opt raw with
      | Some v -> v
      | None -> Full)
  | None -> Full

(* Snapshot TTL cache with same-key deduplication (singleflight).
   When multiple fibers hit a cache miss for the same key concurrently,
   only one computes; the rest wait for its result via Eio.Condition.
   This prevents memory bursts during keeper autoboot where many
   concurrent dashboard polls would each build heavy keeper snapshots. *)

type snapshot_slot =
  | Cached of { value : Yojson.Safe.t; expires_at : float }
  | Computing of { cond : Eio.Condition.t }

let _snapshot_table : (string, snapshot_slot) Hashtbl.t = Hashtbl.create 4
let _snapshot_mu = Eio.Mutex.create ()

let _snapshot_ttl_s = Env_config.Operator.cache_ttl_sec

(* Maximum snapshot cache entries.  Each entry holds a full JSON snapshot
   tree which can be several MB.  Unbounded growth caused OOM when the
   dashboard was connected for extended periods (#4795). *)
let _snapshot_max_entries = 16

(* Evict one expired or oldest entry when table reaches _snapshot_max_entries.
   Called inside _snapshot_mu when Eio is ready; pre-Eio callers are
   single-threaded so no lock is needed. *)
let _maybe_evict_snapshot () =
  if Hashtbl.length _snapshot_table >= _snapshot_max_entries then begin
    let now_ts = Time_compat.now () in
    (* Prefer expired entries *)
    let victim = ref None in
    Hashtbl.iter (fun key slot ->
      match slot, !victim with
      | Cached { expires_at; _ }, None when now_ts >= expires_at ->
        victim := Some key
      | _ -> ()
    ) _snapshot_table;
    (match !victim with
     | Some key -> Hashtbl.remove _snapshot_table key
     | None ->
       (* All fresh or computing — evict the entry closest to expiry *)
       let oldest_cached = ref None in
       let any_key = ref None in
       Hashtbl.iter (fun key slot ->
         match slot with
         | Cached { expires_at; _ } ->
           (match !oldest_cached with
            | None -> oldest_cached := Some (key, expires_at)
            | Some (_, e) when expires_at < e -> oldest_cached := Some (key, expires_at)
            | _ -> ())
         | Computing _ ->
           if !any_key = None then any_key := Some key
       ) _snapshot_table;
       (match !oldest_cached with
        | Some (key, _) -> Hashtbl.remove _snapshot_table key
        | None ->
          (* Last resort: evict a Computing slot to enforce the cap *)
          (match !any_key with
           | Some key -> Hashtbl.remove _snapshot_table key
           | None -> ())))
  end

let invalidate_snapshot_cache () =
  if Eio_guard.is_ready () then begin
    let conds =
      Eio.Mutex.use_rw ~protect:true _snapshot_mu (fun () ->
        let cs = Hashtbl.fold (fun _key slot acc ->
          match slot with Computing { cond } -> cond :: acc | _ -> acc
        ) _snapshot_table [] in
        Hashtbl.clear _snapshot_table;
        cs)
    in
    List.iter Eio.Condition.broadcast conds
  end else
    Hashtbl.clear _snapshot_table

let namespace_scope_cache_segment (_config : Coord_utils.config) = "default"

let snapshot_json ?actor ?view ?(include_messages = true)
    ?(include_keepers = true) ?(include_summary_fields = true)
    ?(lightweight_summary = false)
    (ctx : 'a context) : Yojson.Safe.t =
  let cache_key =
    Printf.sprintf "%s|%s|%s|%s|%b|%b|%b|%b"
      ctx.config.base_path
      (namespace_scope_cache_segment ctx.config)
      (Option.value ~default:"" actor)
      (Option.value ~default:"" view)
      include_messages include_keepers include_summary_fields
      lightweight_summary
  in
  (* Singleflight cache lookup: check for fresh hit, in-flight compute,
     or start a new compute.  Uses Eio.Mutex for safe Hashtbl access.
     Waiters use poll-retry (not Condition.await inside protect:true)
     to stay cancellable — same pattern as Dashboard_cache. *)
  let _max_wait_s = 60.0 in
  let _poll_interval_s = 0.25 in
  let rec cache_lookup ~waited =
    if not (Eio_guard.is_ready ()) then
      (* Pre-Eio: no concurrency, compute directly *)
      let now = Time_compat.now () in
      match Hashtbl.find_opt _snapshot_table cache_key with
      | Some (Cached { value; expires_at }) when now < expires_at -> value
      | _ ->
        let result = compute_snapshot () in
        let ts = Time_compat.now () in
        _maybe_evict_snapshot ();
        Hashtbl.replace _snapshot_table cache_key
          (Cached { value = result; expires_at = ts +. _snapshot_ttl_s });
        result
    else
      let action =
        Eio.Mutex.use_rw ~protect:true _snapshot_mu (fun () ->
          match Hashtbl.find_opt _snapshot_table cache_key with
          | Some (Cached { value; expires_at }) when Time_compat.now () < expires_at ->
            `Hit value
          | Some (Computing { cond }) ->
            if waited >= _max_wait_s then begin
              (* Stuck compute — evict and take over *)
              Log.Dashboard.warn
                "[snapshot_json] evicting stuck Computing slot for %s (%.1fs waited)"
                cache_key waited;
              Hashtbl.remove _snapshot_table cache_key;
              Eio.Condition.broadcast cond;
              let new_cond = Eio.Condition.create () in
              _maybe_evict_snapshot ();
              Hashtbl.replace _snapshot_table cache_key (Computing { cond = new_cond });
              `Compute new_cond
            end else
              `Wait
          | _ ->
            let cond = Eio.Condition.create () in
            _maybe_evict_snapshot ();
            Hashtbl.replace _snapshot_table cache_key (Computing { cond });
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
             | Some (Computing { cond = c }) when c == cond ->
               _maybe_evict_snapshot ();
               Hashtbl.replace _snapshot_table cache_key
                 (Cached { value = result; expires_at = ts +. _snapshot_ttl_s })
             | _ -> ());
           Eio.Condition.broadcast cond;
           result
         | exception exn ->
           let bt = Printexc.get_raw_backtrace () in
           Eio.Mutex.use_rw ~protect:true _snapshot_mu (fun () ->
             match Hashtbl.find_opt _snapshot_table cache_key with
             | Some (Computing { cond = c }) when c == cond ->
               Hashtbl.remove _snapshot_table cache_key
             | _ -> ());
           Eio.Condition.broadcast cond;
           Printexc.raise_with_backtrace exn bt)
  and compute_snapshot () =
  let t0 = Time_compat.now () in
  let timing_records = ref [] in
  let timed label f =
    let t_start = Time_compat.now () in
    let result = f () in
    let elapsed = Time_compat.now () -. t_start in
    timing_records := (label, elapsed) :: !timing_records;
    if elapsed > 0.5 then
      Log.Dashboard.info "[snapshot_json] %s: %.0fms" label (elapsed *. 1000.0);
    result
  in
  let config = ctx.config in
  let initialized = Coord.is_initialized config in
  ignore (initialized, _snapshot_session_window_seconds (), _snapshot_session_limit ());
  let trace_id = trace_id "ops" in
  let actor_name = normalized_actor ~context_actor:ctx.agent_name actor in
  let view = parse_snapshot_view view in
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
  let summary_fields = timed "summary_fields" (fun () ->
    if include_summary_fields
       && initialized
       && (match view with Summary | Full -> true | _ -> false)
    then
      let room_attention =
        build_room_attention_items config
        |> List.sort compare_attention
      in
      let room_recommendation_items =
        room_recommendations config
      in
      [
        ("attention_summary", summary_of_attention_items room_attention);
        ( "recommendation_summary",
          summary_of_recommendations ~actor:actor_name room_recommendation_items );
      ]
    else [])
  in
  let keeper_names =
    if initialized && include_keepers then
      Keeper_types.keeper_names config
    else []
  in
  let persistent_keeper_names =
    if initialized && include_keepers then
      Keeper_types.persistent_agent_names config
    else []
  in
  let result =
    `Assoc
      ([
         ("trace_id", `String trace_id);
         ("server_profile", operator_server_profile_json);
         ("operator_judge_runtime", operator_judge_runtime_json config);
         ("judgment_owner", `String "fallback_read_model");
         ("authoritative_judgment_available", `Bool false);
         ("root", room_json config);
       ]
      @ (
         (* Parallelize independent I/O: sessions, keepers, and persistent_agents. *)
         let empty_section = `Assoc [ ("count", `Int 0); ("items", `List []) ] in
         let sessions_ref = ref empty_section in
         let keepers_ref = ref empty_section in
         let persistent_ref = ref empty_section in
         Eio.Fiber.all [
           (fun () ->
             (* Team sessions removed — always empty *)
             ignore (lightweight_summary, status_cache);
             sessions_ref := empty_section);
           (fun () ->
             let keepers_json_value =
               timed "keepers_json" (fun () ->
                 if initialized && include_keepers then
                   keepers_json ~keeper_names ~lightweight:lightweight_summary
                     ~include_recent_activity:(not lightweight_summary) config
                 else empty_section)
             in
             keepers_ref := keepers_json_value;
             persistent_ref :=
               timed "persistent_agents_json" (fun () ->
                 if initialized && include_keepers then
                   let keeper_rows =
                     match keepers_json_value with
                     | `Assoc fields -> (
                         match List.assoc_opt "items" fields with
                         | Some (`List rows) -> rows
                         | _ -> [])
                     | _ -> []
                   in
                   persistent_agents_json ~keeper_names:persistent_keeper_names
                     ~keeper_rows config
                 else empty_section));
         ];
         [
           ("sessions", !sessions_ref);
           ("keepers", !keepers_ref);
           ("persistent_agents", !persistent_ref);
         ]
      )
      @ [
         ( "recent_messages",
           if initialized && include_messages && not lightweight_summary then
             recent_messages_json config
           else
             `List [] );
       ]
      @ (let confirm_scope = timed "pending_confirms" (fun () ->
           pending_confirm_scope ?actor config) in
         [
           ("pending_confirms",
             `List (List.map pending_confirm_to_yojson confirm_scope.visible_entries));
           ("pending_confirm_envelope",
             `Assoc [
               ("items", `List (List.map pending_confirm_to_yojson confirm_scope.visible_entries));
               ("summary", pending_confirm_summary_json_of_scope confirm_scope);
             ]);
           ("pending_confirm_summary", pending_confirm_summary_json_of_scope confirm_scope);
         ])
      @ [
         ("available_actions", available_actions_json);
         ( "recent_actions",
           if lightweight_summary then `List [] else recent_actions_json config );
       ]
      @ summary_fields)
  in
  let elapsed_total = Time_compat.now () -. t0 in
  if elapsed_total > 1.0 then begin
    Log.Dashboard.info "[snapshot_json] total: %.0fms (sessions=%d keepers=%d)"
      (elapsed_total *. 1000.0)
      0 (List.length keeper_names);
    List.iter (fun (label, dt) ->
      if dt > 0.1 then
        Log.Dashboard.info "[snapshot_json]   %s: %.0fms" label (dt *. 1000.0))
      (List.rev !timing_records)
  end;
  result
  in
  cache_lookup ~waited:0.0
