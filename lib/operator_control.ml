module U = Yojson.Safe.Util
open Tool_args

let ( let* ) = Result.bind

include Operator_pending_confirm
include Operator_digest

type action_log_entry = {
  trace_id : string;
  actor : string;
  remote_session_id : string option;
  remote_client_type : string;
  action_type : string;
  target_type : string;
  target_id : string option;
  delegated_tool : string;
  confirmation_state : string;
  result_status : string;
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
      ("confirmation_state", `String entry.confirmation_state);
      ("result_status", `String entry.result_status);
      ("latency_ms", `Int entry.latency_ms);
      ("created_at", `String entry.created_at);
    ]

let append_action_log config (entry : action_log_entry) =
  Room_utils.mkdir_p (operator_dir config);
  let oc =
    open_out_gen [ Open_creat; Open_text; Open_append ] 0o644
      (action_log_path config)
  in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc (Yojson.Safe.to_string (action_log_entry_to_yojson entry));
      output_char oc '\n')

let recent_actions_json config =
  if not (Sys.file_exists (action_log_path config)) then
    `List []
  else
    let lines =
      In_channel.with_open_text (action_log_path config) In_channel.input_lines
    in
    let tail =
      let rev = List.rev lines in
      rev |> List.to_seq |> Seq.take 20 |> List.of_seq |> List.rev
    in
    let items =
      tail
      |> List.filter_map (fun line ->
             try Some (Yojson.Safe.from_string line) with Yojson.Json_error _ -> None)
    in
    `List items

let recent_messages_json config =
  Room.get_messages_raw config ~since_seq:0 ~limit:20
  |> List.map Types.message_to_yojson
  |> fun rows -> `List rows

let latest_keeper_tools_from_metrics config keeper_name =
  let metrics_path = Keeper_types.keeper_metrics_path config keeper_name in
  Keeper_memory.read_file_tail_lines metrics_path ~max_bytes:40000 ~max_lines:8
  |> List.rev
  |> List.find_map (fun line ->
         try
           let json = Yojson.Safe.from_string line in
           let tools =
             match Yojson.Safe.Util.member "tools_used" json with
             | `List items ->
                 items
                 |> List.filter_map (function
                        | `String tool ->
                            let trimmed = String.trim tool in
                            if trimmed = "" then None else Some trimmed
                        | _ -> None)
             | _ -> []
           in
           if tools = [] then None else Some (List.sort_uniq String.compare tools)
         with Yojson.Json_error _ -> None)
  |> Option.value ~default:[]

let keeper_tool_audit_fields config (meta : Keeper_types.keeper_meta) =
  let fallback_allowed = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let fallback_latest = latest_keeper_tools_from_metrics config meta.name in
  let fallback_count = None in
  let fallback_source =
    if fallback_latest <> [] then Some "keeper_metrics" else None
  in
  let fallback_at =
    let last_autonomous = String.trim meta.last_autonomous_action_at in
    if last_autonomous <> "" then Some last_autonomous
    else Some meta.updated_at
  in
  match A2a_tools.latest_heartbeat_task meta.agent_name,
        A2a_tools.latest_heartbeat_result meta.agent_name with
  | Some task, Some result ->
      if task.seq > result.seq then
        ( task.allowed_tools,
          result.tool_names,
          Some result.tool_call_count,
          Some "heartbeat_task_pending_result",
          Some task.created_at )
      else
        ( task.allowed_tools,
          result.tool_names,
          Some result.tool_call_count,
          Some "heartbeat_result",
          Some result.updated_at )
  | Some task, None ->
      (task.allowed_tools, [], None, Some "heartbeat_task", Some task.created_at)
  | None, Some result ->
      ( fallback_allowed,
        result.tool_names,
        Some result.tool_call_count,
        Some "heartbeat_result",
        Some result.updated_at )
  | None, None ->
      (fallback_allowed, fallback_latest, fallback_count, fallback_source, fallback_at)

let keepers_json ?keeper_names config =
  let names = match keeper_names with
    | Some n -> n
    | None -> Keeper_types.resident_keeper_names config
  in
  let rows =
    List.filter_map
      (fun name ->
        match Keeper_types.read_meta config name with
        | Error _ | Ok None -> None
        | Ok (Some meta) ->
            let agent_json =
              Keeper_exec_status.parse_agent_status config ~agent_name:meta.agent_name
            in
            let keepalive_running =
              Keeper_keepalive.keeper_keepalive_running meta.name
            in
            let agent_exists =
              match agent_json |> U.member "exists" with
              | `Bool value -> value
              | _ -> false
            in
            let now_ts = Time_compat.now () in
            let keepalive_started_at =
              Keeper_keepalive.keeper_keepalive_started_at meta.name
            in
            let diagnostic =
              Keeper_exec_status.keeper_diagnostic_json ~meta
                ~agent_status:agent_json ~keepalive_running ~history_items:[]
                ~now_ts
              |> Keeper_exec_status.augment_keeper_diagnostic_json ~desired:true
                   ~meta ~keepalive_running ~keepalive_started_at ~now_ts
            in
            let allowed_tool_names, latest_tool_names, latest_tool_call_count,
                tool_audit_source, tool_audit_at =
              keeper_tool_audit_fields config meta
            in
            let agent_status =
              if not agent_exists then "offline"
              else Keeper_exec_status.keeper_surface_status ~agent_status:agent_json ~diagnostic
            in
            Some
              (`Assoc
                [
                  ("runtime_class", `String "resident_keeper");
                  ("desired", `Bool true);
                  ("resident_registered", `Bool true);
                  ("name", `String meta.name);
                  ("agent_name", `String meta.agent_name);
                  ("trace_id", `String meta.trace_id);
                  ("goal", `String meta.goal);
                  ("short_goal", `String meta.short_goal);
                  ("mid_goal", `String meta.mid_goal);
                  ("long_goal", `String meta.long_goal);
                  ("status", `String agent_status);
                  ("agent", agent_json);
                  ("diagnostic", diagnostic);
                  ("generation", `Int meta.generation);
                  ("turn_count", `Int meta.total_turns);
                  ("context_ratio", `Null);
                  ("context_tokens", `Int meta.last_total_tokens);
                  ("last_model_used", `String meta.last_model_used);
                  ("active_model", `String (Keeper_exec_status.active_model_of_meta meta));
                  ("keepalive_running", `Bool keepalive_running);
                  ( "next_model_hint",
                    string_option_to_json (Keeper_exec_status.next_model_hint_of_meta meta)
                  );
                  ("autonomy_level", `String meta.autonomy_level);
                  ( "active_goal_ids",
                    `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids)
                  );
                  ( "last_autonomous_action_at",
                    if String.trim meta.last_autonomous_action_at = "" then `Null
                    else `String meta.last_autonomous_action_at );
                  ("autonomous_action_count", `Int meta.autonomous_action_count);
                  ("allowed_tool_names", `List (List.map (fun value -> `String value) allowed_tool_names));
                  ("latest_tool_names", `List (List.map (fun value -> `String value) latest_tool_names));
                  ("recent_tool_names", `List (List.map (fun value -> `String value) latest_tool_names));
                  ("latest_tool_call_count", option_to_json (fun value -> `Int value) latest_tool_call_count);
                  ("tool_audit_source", string_option_to_json tool_audit_source);
                  ("tool_audit_at", string_option_to_json tool_audit_at);
                  ("updated_at", `String meta.updated_at);
                  ("created_at", `String meta.created_at);
                  ("recent_activity",
                    let metrics_path = Keeper_types.keeper_metrics_path config name in
                    let lines =
                      Keeper_memory.read_file_tail_lines metrics_path
                        ~max_bytes:8000 ~max_lines:5
                    in
                    `List (List.filter_map (fun line ->
                      try Some (Yojson.Safe.from_string line)
                      with Yojson.Json_error _ -> None) lines));
                ]))
      names
  in
  `Assoc [ ("count", `Int (List.length rows)); ("items", `List rows) ]

let persistent_agents_json ?keeper_names config =
  let names = Keeper_types.persistent_agent_names ?resident_names:keeper_names config in
  let rows =
    List.filter_map
      (fun name ->
        match Keeper_types.read_meta config name with
        | Error _ | Ok None -> None
        | Ok (Some meta) ->
            let agent_json =
              Keeper_exec_status.parse_agent_status config ~agent_name:meta.agent_name
            in
            let agent_status =
              match agent_json |> U.member "status" with
              | `String status -> status
              | _ -> "unknown"
            in
            Some
              (`Assoc
                [
                  ("runtime_class", `String "persistent_agent");
                  ("desired", `Bool false);
                  ("resident_registered", `Bool false);
                  ("name", `String meta.name);
                  ("agent_name", `String meta.agent_name);
                  ("trace_id", `String meta.trace_id);
                  ("goal", `String meta.goal);
                  ("short_goal", `String meta.short_goal);
                  ("mid_goal", `String meta.mid_goal);
                  ("long_goal", `String meta.long_goal);
                  ("status", `String agent_status);
                  ("generation", `Int meta.generation);
                  ("turn_count", `Int meta.total_turns);
                  ("context_ratio", `Null);
                  ("context_tokens", `Int meta.last_total_tokens);
                  ("last_model_used", `String meta.last_model_used);
                  ("active_model", `String (Keeper_exec_status.active_model_of_meta meta));
                  ("next_model_hint", string_option_to_json (Keeper_exec_status.next_model_hint_of_meta meta));
                  ("autonomy_level", `String meta.autonomy_level);
                  ("active_goal_ids", `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids));
                  ("last_autonomous_action_at",
                    if String.trim meta.last_autonomous_action_at = "" then `Null else `String meta.last_autonomous_action_at);
                  ("autonomous_action_count", `Int meta.autonomous_action_count);
                  ("updated_at", `String meta.updated_at);
                  ("created_at", `String meta.created_at);
                ]))
      names
  in
  `Assoc [ ("count", `Int (List.length rows)); ("items", `List rows) ]

let sessions_json config =
  let sessions =
    Team_session_store.list_sessions config
    |> List.sort (fun (a : Team_session_types.session) (b : Team_session_types.session) ->
           compare b.started_at a.started_at)
  in
  let items =
    List.map
      (fun (session : Team_session_types.session) ->
        let recent_events =
          Team_session_store.read_events ~max_events:200 config session.session_id
          |> Team_session_engine_eio.take_last 5
        in
        `Assoc
          [
            ("session_id", `String session.session_id);
            ("command_plane_operation_id", `String ("detachment-" ^ session.session_id));
            ("command_plane_detachment_id", `String ("detachment-" ^ session.session_id));
            ("status", Team_session_engine_eio.session_status_json config session);
            ("recent_events", `List recent_events);
          ])
      sessions
  in
  `Assoc [ ("count", `Int (List.length items)); ("items", `List items) ]

let room_json config =
  let initialized = Room.is_initialized config in
  if not initialized then
    `Assoc
      [
        ("initialized", `Bool false);
        ("project", `String (Filename.basename config.base_path));
      ]
  else
    let state = Room.read_state config in
    let tempo = Tempo.get_tempo config in
    let tasks = Room.get_tasks_raw config in
    let agents = Room.get_agents_raw config in
    `Assoc
      [
        ("initialized", `Bool true);
        ("cluster", `String (Option.value ~default:"default" (Sys.getenv_opt "MASC_CLUSTER_NAME")));
        ("project", `String state.project);
        ("current_room", string_option_to_json (Room.read_current_room config));
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

let parse_snapshot_view = function
  | Some raw -> (
      match String.trim raw |> String.lowercase_ascii with
      | "summary" -> Summary
      | "sessions" -> Sessions
      | "keepers" -> Keepers
      | "messages" -> Messages
      | _ -> Full)
  | None -> Full

(* Snapshot TTL cache: avoids redundant DB queries on repeated calls
   (dashboard SSE polling, multiple MCP clients). *)
let _snapshot_cache : (string * Yojson.Safe.t * float) option ref = ref None

let _snapshot_ttl_s =
  match Sys.getenv_opt "MASC_OPERATOR_CACHE_TTL" with
  | Some s -> (try Float.of_string s with _ -> 5.0)
  | None -> 5.0

let invalidate_snapshot_cache () = _snapshot_cache := None

let snapshot_json ?actor ?view ?(include_messages = true) ?(include_sessions = true)
    ?(include_keepers = true) ?sessions (ctx : 'a context) : Yojson.Safe.t =
  let cache_key =
    Printf.sprintf "%s|%s|%b|%b|%b"
      (Option.value ~default:"" actor)
      (Option.value ~default:"" view)
      include_messages include_sessions include_keepers
  in
  let now = Time_compat.now () in
  (match !_snapshot_cache with
   | Some (k, json, ts) when k = cache_key && now -. ts < _snapshot_ttl_s ->
       json
   | _ ->
  let config = ctx.config in
  let initialized = Room.is_initialized config in
  let tracked_sessions =
    match sessions with
    | Some s -> s
    | None ->
        if initialized then Team_session_store.list_sessions config else []
  in
  let trace_id = trace_id "ops" in
  let actor_name = normalized_actor ~context_actor:ctx.agent_name actor in
  let view = parse_snapshot_view view in
  let include_sessions =
    include_sessions
    &&
    match view with
    | Summary | Sessions | Full -> true
    | Keepers | Messages -> false
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
  let command_plane_summary =
    if initialized then
      Some (Command_plane_v2.summary_json ~sessions:tracked_sessions config)
    else None
  in
  let summary_fields =
    if initialized && (match view with Summary | Full -> true | _ -> false) then
      let now = Time_compat.now () in
      let session_digests =
        tracked_sessions
        |> List.map (fun session -> build_session_digest config session ~now)
      in
      let room_attention =
        build_room_attention_items ?command_plane_summary config
        @ (session_digests |> List.concat_map (fun digest -> digest.attention_items))
        |> List.sort compare_attention
      in
      let room_recommendation_items =
        room_recommendations ?command_plane_summary config
        @ (session_digests |> List.concat_map (fun digest -> digest.recommended_actions))
      in
      [
        ("attention_summary", summary_of_attention_items room_attention);
        ( "recommendation_summary",
          summary_of_recommendations ~actor:actor_name room_recommendation_items );
      ]
    else []
  in
  let command_plane_json =
    if initialized then Command_plane_v2.snapshot_json config else `Assoc []
  in
  let swarm_status_json =
    if initialized then
      Swarm_status.build_json_from_snapshot config command_plane_json
    else
      Swarm_status.empty_json
  in
  let keeper_names =
    if initialized && include_keepers then
      Keeper_types.resident_keeper_names config
    else []
  in
  let result =
    `Assoc
      ([
         ("trace_id", `String trace_id);
         ("server_profile", operator_server_profile_json);
         ("resident_judge_runtime", resident_judge_runtime_json config);
         ("judgment_owner", `String "fallback_read_model");
         ("authoritative_judgment_available", `Bool false);
         ("provenance_summary", operator_surface_contract_json);
         ("room", room_json config);
         ( "sessions",
           if initialized && include_sessions then sessions_json config
           else `Assoc [ ("count", `Int 0); ("items", `List []) ] );
         ( "keepers",
           if initialized && include_keepers then keepers_json ~keeper_names config
           else `Assoc [ ("count", `Int 0); ("items", `List []) ] );
         ( "persistent_agents",
           if initialized && include_keepers then persistent_agents_json ~keeper_names config
           else `Assoc [ ("count", `Int 0); ("items", `List []) ] );
         ("command_plane", command_plane_json);
         ("swarm_status", swarm_status_json);
         ("role_census", aggregate_worker_class_counts tracked_sessions);
         ("runtime_pools", aggregate_runtime_pool_counts tracked_sessions);
         ("lane_census", aggregate_lane_counts tracked_sessions);
         ("controller_census", aggregate_controller_counts tracked_sessions);
         ("control_domains", aggregate_control_domain_counts tracked_sessions);
         ("model_tiers", aggregate_tier_counts tracked_sessions);
         ("task_profiles", aggregate_task_profile_counts tracked_sessions);
         ("escalation_count", `Int (aggregate_escalation_count tracked_sessions));
         ("local_runtime", aggregated_local_runtime_json tracked_sessions);
         ("recent_messages", if initialized && include_messages then recent_messages_json config else `List []);
         ("pending_confirms", pending_confirms_json ?actor config);
         ("pending_confirm_envelope", pending_confirm_envelope_json ?actor config);
         ("pending_confirm_summary", pending_confirm_summary_json ?actor config);
         ("available_actions", available_actions_json);
         ("recent_actions", recent_actions_json config);
       ]
      @ summary_fields)
  in
  _snapshot_cache := Some (cache_key, result, now);
  result)


let judgment_surface_enums =
  [ "command.warroom"; "command.swarm"; "intervene" ]

let normalize_judgment_surface value =
  let normalized = String.trim value |> String.lowercase_ascii in
  if List.mem normalized judgment_surface_enums then Ok normalized
  else Error "surface must be one of command.warroom, command.swarm, intervene"

let normalize_judgment_target_type value =
  let normalized = String.trim value |> String.lowercase_ascii in
  match normalized with
  | "room" -> Ok ("room", Operator_judgment.Room)
  | "team_session" -> Ok ("team_session", Operator_judgment.Team_session)
  | _ -> Error "target_type must be room or team_session"

let default_fresh_ttl_sec surface =
  match surface with
  | "command.warroom" -> 60
  | "command.swarm" | "intervene" -> 300
  | _ -> 120

let judgment_write_json (ctx : 'a context) args =
  let* surface = normalize_judgment_surface (get_string args "surface" "") in
  let* _, judgment_target_type =
    normalize_judgment_target_type (get_string args "target_type" "")
  in
  let target_id = get_string_opt args "target_id" in
  let summary = get_string args "summary" "" |> String.trim in
  if summary = "" then Error "summary is required"
  else if
    judgment_target_type = Operator_judgment.Team_session && Option.is_none target_id
  then
    Error "target_id is required when target_type=team_session"
  else
    let now_unix = Unix.gettimeofday () in
    let generated_at = iso_of_unix now_unix in
    let fresh_ttl_sec =
      let default = default_fresh_ttl_sec surface in
      max 1 (get_int args "fresh_ttl_sec" default)
    in
    let fresh_until_unix = now_unix +. float_of_int fresh_ttl_sec in
    let fresh_until = iso_of_unix fresh_until_unix in
    let confidence = get_float args "confidence" 0.5 in
    let keeper_name =
      match get_string_opt args "keeper_name" with
      | Some raw when String.trim raw <> "" -> String.trim raw
      | _ -> normalized_actor ~context_actor:ctx.agent_name None
    in
    let evidence_refs =
      match U.member "evidence_refs" args with
      | `List items -> List.filter_map U.to_string_option items
      | _ -> []
    in
    let recommended_action =
      match U.member "recommended_action" args with
      | `Assoc _ as value -> Some value
      | _ -> None
    in
    let judgment =
      Operator_judgment.record ctx.config ~surface
        ~target_type:judgment_target_type ~target_id ~summary ~confidence
        ?model_name:(get_string_opt args "model_name")
        ?runtime_name:(get_string_opt args "runtime_name")
        ?recommended_action ~evidence_refs
        ~fallback_used:(get_bool args "fallback_used" false)
        ~disagreement_with_truth:
          (get_bool args "disagreement_with_truth" false)
        ~generated_at ~generated_at_unix:now_unix ~fresh_until ~fresh_until_unix
        ~keeper_name ()
    in
    Ok
      (`Assoc
        [
          ("status", `String "ok");
          ("judgment", Operator_judgment.to_yojson judgment);
        ])

let judgment_latest_json (_ctx : 'a context) args =
  let* surface = normalize_judgment_surface (get_string args "surface" "") in
  let* _, judgment_target_type =
    normalize_judgment_target_type (get_string args "target_type" "")
  in
  let target_id = get_string_opt args "target_id" in
  if
    judgment_target_type = Operator_judgment.Team_session && Option.is_none target_id
  then
    Error "target_id is required when target_type=team_session"
  else
    let require_fresh = get_bool args "require_fresh" true in
    let judgment =
      match
        Operator_judgment.latest_active _ctx.config ~surface
          ~target_type:judgment_target_type ~target_id
      with
      | Some value when (not require_fresh) || Operator_judgment.is_fresh value ->
          Some value
      | _ -> None
    in
    Ok
      (`Assoc
        [
          ("status", `String "ok");
          ( "judgment",
            match judgment with
            | Some value -> Operator_judgment.to_yojson value
            | None -> `Null );
        ])

type action_request = {
  actor : string;
  action_type : string;
  target_type : string;
  target_id : string option;
  payload : Yojson.Safe.t;
}

let canonical_action_type action_type =
  match action_type with
  | "lodge_poke" -> "social_sweep"
  | "lodge_tick" -> "social_sweep"
  | "social_sweep" -> "social_sweep"
  | "team_turn" -> "team_turn"
  | "team_note" -> "team_note"
  | "team_broadcast" -> "team_broadcast"
  | "team_task_inject" -> "team_task_inject"
  | "team_worker_spawn_batch" -> "team_worker_spawn_batch"
  | "keeper_msg" -> "keeper_message"
  | "keeper_message" -> "keeper_message"
  | "keeper_probe" -> "keeper_probe"
  | "keeper_recover" -> "keeper_recover"
  | "swarm_run_continue" -> "swarm_run_continue"
  | "swarm_run_rerun" -> "swarm_run_rerun"
  | "swarm_run_abandon" -> "swarm_run_abandon"
  | other -> other

let default_target_type_for action_type =
  match action_type with
  | "broadcast" | "room_pause" | "room_resume" | "task_inject" | "social_sweep" -> "room"
  | "team_turn" | "team_note" | "team_broadcast" | "team_task_inject"
  | "team_worker_spawn_batch" | "team_stop" ->
      "team_session"
  | "keeper_message" | "keeper_probe" | "keeper_recover" -> "keeper"
  | "swarm_run_continue" | "swarm_run_rerun" | "swarm_run_abandon" ->
      "swarm_run"
  | _ -> ""

let generate_confirm_token ~(clock : _ Eio.Time.clock) config =
  let max_attempts = 10 in
  let rec loop attempts =
    if attempts >= max_attempts then
      Error (Printf.sprintf
        "failed to generate unique confirm token after %d attempts \
         (token space may be exhausted; %d pending confirms)"
        max_attempts
        (List.length (raw_pending_confirms config)))
    else
      let token = "opc_" ^ String.sub (Auth.generate_token ()) 0 32 in
      let exists =
        raw_pending_confirms config
        |> List.exists (fun entry -> String.equal entry.token token)
      in
      if exists then begin
        (* Exponential backoff: 1ms, 2ms, 4ms, ... up to ~512ms *)
        let backoff_s = float_of_int (1000 * (1 lsl (min attempts 9))) /. 1_000_000.0 in
        Eio.Time.sleep clock backoff_s;
        loop (attempts + 1)
      end else Ok token
  in
  loop 0

let resolved_actor_for_args ?actor_hint ctx args =
  let payload_actor = get_string_opt args "actor" |> Option.map String.trim in
  let hinted_actor = actor_hint |> Option.map String.trim in
  match (payload_actor, hinted_actor) with
  | Some payload, Some hinted
    when payload <> "" && hinted <> "" && not (String.equal payload hinted) ->
      Error "actor mismatch: payload actor must match authenticated actor"
  | _ ->
      Ok
        (normalized_actor ~context_actor:ctx.agent_name
           (match hinted_actor with
           | Some actor when actor <> "" -> Some actor
           | _ -> payload_actor))

let action_request_of_args ?actor_hint ctx args =
  let action_type =
    get_string args "action_type" "" |> String.trim |> String.lowercase_ascii
    |> canonical_action_type
  in
  let raw_target_type =
    get_string args "target_type" "" |> String.trim |> String.lowercase_ascii
  in
  let* actor = resolved_actor_for_args ?actor_hint ctx args in
  Ok
    {
      actor;
      action_type;
      target_type =
        if raw_target_type <> "" then raw_target_type
        else default_target_type_for action_type;
      target_id = get_string_opt args "target_id";
      payload = get_payload args;
    }

let delegated_tool_for action_type =
  match action_type with
  | "broadcast" -> "masc_broadcast"
  | "room_pause" -> "masc_pause"
  | "room_resume" -> "masc_resume"
  | "social_sweep" -> "social_sweep"
  | "team_turn" | "team_note" | "team_broadcast" | "team_task_inject" ->
      "masc_team_session_step"
  | "team_worker_spawn_batch" -> "masc_team_session_step"
  | "team_stop" -> "masc_team_session_stop"
  | "keeper_message" -> "masc_keeper_msg"
  | "keeper_probe" -> "masc_keeper_status"
  | "keeper_recover" -> "masc_keeper_recover"
  | "swarm_run_continue" -> "swarm_run_continue_chain"
  | "swarm_run_rerun" -> "masc_swarm_live_run"
  | "swarm_run_abandon" -> "swarm_run_resolution"
  | "task_inject" -> "masc_add_task"
  | _ -> "unknown"

let confirm_required = function
  | "room_pause" | "team_stop" | "task_inject" | "team_task_inject"
  | "team_worker_spawn_batch" | "swarm_run_continue"
  | "swarm_run_rerun" | "swarm_run_abandon" ->
      true
  | _ -> false

let preview_of_action (request : action_request) =
  let base =
    [
      ("actor", `String request.actor);
      ("action_type", `String request.action_type);
      ("target_type", `String request.target_type);
      ("target_id", string_option_to_json request.target_id);
    ]
  in
  let payload_fields =
    match request.payload with
    | `Assoc fields -> fields
    | _ -> []
  in
  `Assoc (base @ [ ("payload", `Assoc payload_fields) ])

let validate_target_type expected request =
  if String.equal request.target_type expected then Ok ()
  else
    Error
      (Printf.sprintf "invalid target_type for %s (expected %s)"
         request.action_type expected)

let require_target_id request =
  match request.target_id with
  | Some target_id -> Ok target_id
  | None -> Error "target_id is required"

let require_payload_field payload key error_message =
  match get_string_opt payload key with
  | Some value -> Ok value
  | None -> Error error_message

let parse_turn_kind payload =
  let raw =
    get_string payload "turn_kind" "" |> String.trim |> String.lowercase_ascii
  in
  match Team_session_types.turn_kind_of_string raw with
  | Some turn_kind -> Ok turn_kind
  | None when raw = "" -> Error "payload.turn_kind is required"
  | None ->
      Error
        "payload.turn_kind must be one of: note, broadcast, portal, task, checkpoint"

let swarm_run_json_for_request (ctx : 'a context) (request : action_request) =
  let* run_id = require_target_id request in
  let operation_id = get_string_opt request.payload "operation_id" in
  Ok (Command_plane_v2.swarm_live_json ctx.config ~run_id ?operation_id ())

let swarm_run_recommendation_json swarm_json =
  match U.member "resolution_recommendation" swarm_json with
  | `Assoc _ as json -> Some json
  | _ -> None

let swarm_run_operation_id swarm_json =
  match U.member "operation" swarm_json with
  | `Assoc _ as operation ->
      operation |> U.member "operation_id" |> U.to_string_option
  | _ -> None

let swarm_run_detachment_id swarm_json =
  match U.member "detachment" swarm_json with
  | `Assoc _ as detachment ->
      detachment |> U.member "detachment_id" |> U.to_string_option
  | _ -> None

let swarm_run_reason swarm_json fallback =
  match swarm_run_recommendation_json swarm_json with
  | Some json -> (
      match U.member "reason" json with
      | `String reason when String.trim reason <> "" -> reason
      | _ -> fallback)
  | None -> fallback

let swarm_run_chain_preview (request : action_request) swarm_json =
  let run_id =
    swarm_json |> U.member "run_id" |> U.to_string_option
    |> Option.value ~default:(Option.value ~default:"swarm-live" request.target_id)
  in
  let reason =
    swarm_run_reason swarm_json "swarm-live run needs operator resolution"
  in
  let operation_id = swarm_run_operation_id swarm_json in
  let detachment_id = swarm_run_detachment_id swarm_json in
  let base_fields =
    [
      ("run_id", `String run_id);
      ("reason", `String reason);
      ("provenance", `String "derived");
      ("decision_engine", `String "deterministic_truth_map");
      ("authoritative", `Bool false);
    ]
  in
  let evidence =
    match swarm_run_recommendation_json swarm_json with
    | Some json -> (
        match U.member "evidence" json with
        | `Assoc _ as evidence -> evidence
        | _ -> `Assoc [])
    | None -> `Assoc []
  in
  match request.action_type with
  | "swarm_run_continue" ->
      let steps =
        (match
           swarm_json |> U.member "operation" |> U.member "status"
           |> U.to_string_option
         with
        | Some "paused" -> [ `Assoc [ ("tool", `String "masc_operation_resume"); ("args", `Assoc [ ("operation_id", option_to_json (fun value -> `String value) operation_id) ]) ] ]
        | _ -> [])
        @
        (match operation_id, detachment_id with
        | Some value, _ ->
            [ `Assoc [ ("tool", `String "masc_dispatch_tick"); ("args", `Assoc [ ("operation_id", `String value) ]) ] ]
        | None, Some value ->
            [ `Assoc [ ("tool", `String "masc_dispatch_tick"); ("args", `Assoc [ ("detachment_id", `String value) ]) ] ]
        | None, None -> [])
      in
      `Assoc
        (base_fields
        @ [
            ("resolution_kind", `String "continue");
            ("delegated_tools", `List (List.map (fun step -> U.member "tool" step) steps));
            ("tool_chain_preview", `List steps);
            ("evidence", evidence);
          ])
  | "swarm_run_rerun" ->
      let steps =
        [
          `Assoc
            [
              ("tool", `String "masc_swarm_live_run");
              ("args", `Assoc [ ("run_id", `String run_id) ]);
            ];
        ]
      in
      `Assoc
        (base_fields
        @ [
            ("resolution_kind", `String "rerun");
            ("delegated_tools", `List (List.map (fun step -> U.member "tool" step) steps));
            ("tool_chain_preview", `List steps);
            ("evidence", evidence);
          ])
  | "swarm_run_abandon" ->
      `Assoc
        (base_fields
        @ [
            ("resolution_kind", `String "abandon");
            ("delegated_tools", `List []);
            ("tool_chain_preview", `List []);
            ("operation_id", option_to_json (fun value -> `String value) operation_id);
            ("detachment_id", option_to_json (fun value -> `String value) detachment_id);
            ("evidence", evidence);
          ])
  | _ ->
      `Assoc
        [
          ("actor", `String request.actor);
          ("action_type", `String request.action_type);
          ("target_type", `String request.target_type);
          ("target_id", string_option_to_json request.target_id);
          ("payload", request.payload);
        ]

let json_of_dispatch_output body =
  try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body

let tool_keeper_ctx (ctx : 'a context) : _ Tool_keeper.context =
  {
    config = ctx.config;
    agent_name = ctx.agent_name;
    sw = ctx.sw;
    clock = ctx.clock;
    proc_mgr = ctx.proc_mgr;
  }

let tool_command_plane_ctx (ctx : 'a context) : _ Tool_command_plane.context =
  {
    config = ctx.config;
    agent_name = ctx.agent_name;
    sw = Some ctx.sw;
    clock = Some ctx.clock;
    net = None;
    mcp_state = None;
    mcp_session_id = ctx.mcp_session_id;
    auth_token = None;
  }

let dispatch_keeper_json (ctx : 'a context) ~tool_name ~args =
  match Tool_keeper.dispatch (tool_keeper_ctx ctx) ~name:tool_name ~args with
  | Some (true, body) -> Ok (json_of_dispatch_output body)
  | Some (false, err) -> Error err
  | None -> Error (Printf.sprintf "%s dispatch unavailable" tool_name)

let dispatch_command_plane_json (ctx : 'a context) ~tool_name ~args =
  match Tool_command_plane.dispatch (tool_command_plane_ctx ctx) ~name:tool_name ~args with
  | Some (true, body) -> Ok (json_of_dispatch_output body)
  | Some (false, err) -> Error err
  | None -> Error (Printf.sprintf "%s dispatch unavailable" tool_name)

let dispatch_team_session_json_as (ctx : 'a context) ~session_id ~requested_actor
    ~tool_name ~args =
  let* authorized_actor =
    match Team_session_store.load_session ctx.config session_id with
    | None -> Error (Printf.sprintf "team session not found: %s" session_id)
    | Some session ->
        if String.equal requested_actor session.created_by
           || List.exists (String.equal requested_actor) session.agent_names
        then
          Ok requested_actor
        else
          Ok session.created_by
  in
  let args =
    match args with
    | `Assoc fields ->
        `Assoc
          (("actor", `String authorized_actor) :: List.remove_assoc "actor" fields)
    | other -> other
  in
  let team_ctx : _ Tool_team_session.context =
    {
      config = ctx.config;
      agent_name = authorized_actor;
      sw = ctx.sw;
      clock = ctx.clock;
      proc_mgr = ctx.proc_mgr;
    }
  in
  match Tool_team_session.dispatch team_ctx ~name:tool_name ~args with
  | Some (true, body) -> Ok (json_of_dispatch_output body)
  | Some (false, err) -> Error err
  | None -> Error (Printf.sprintf "%s dispatch unavailable" tool_name)

let keeper_diagnostic_health_state json =
  match U.member "health_state" json with
  | `String value -> Some (String.lowercase_ascii value)
  | _ -> None

let keeper_diagnostic_recoverable json =
  match U.member "recoverable" json with
  | `Bool value -> value
  | _ -> false

let keeper_recovery_outcome after_diagnostic =
  match keeper_diagnostic_health_state after_diagnostic with
  | Some ("healthy" | "idle") when not (keeper_diagnostic_recoverable after_diagnostic) ->
      (true, None)
  | Some state ->
      ( false,
        Some
          (Printf.sprintf
             "keeper remained %s after recovery attempt"
             state) )
  | None -> (false, Some "keeper recovery did not return a health_state")

let resolve_team_turn_actor config ~requested_actor ~session_id =
  match Team_session_store.load_session config session_id with
  | None -> Error (Printf.sprintf "team session not found: %s" session_id)
  | Some session ->
      if String.equal requested_actor session.created_by
         || List.exists (String.equal requested_actor) session.agent_names
      then
        Ok (requested_actor, false)
      else
        Ok (session.created_by, true)

let execute_team_turn ~ctx ~request ~session_id ~turn_kind ~message ~target_agent
    ~task_title ~task_description ~task_priority =
  let* actor_for_session, operator_override =
    resolve_team_turn_actor ctx.config ~requested_actor:request.actor ~session_id
  in
  let message =
    if operator_override then
      match message with
      | Some raw -> Some (Printf.sprintf "[operator:%s] %s" request.actor raw)
      | None -> Some (Printf.sprintf "[operator:%s]" request.actor)
    else
      message
  in
  let args =
    let fields =
      [
        ("session_id", `String session_id);
        ("actor", `String actor_for_session);
        ( "turn_kind",
          `String (Team_session_types.turn_kind_to_string turn_kind) );
        ("task_priority", `Int task_priority);
      ]
    in
    let fields =
      match message with
      | Some value -> ("message", `String value) :: fields
      | None -> fields
    in
    let fields =
      match target_agent with
      | Some value -> ("target_agent", `String value) :: fields
      | None -> fields
    in
    let fields =
      match task_title with
      | Some value -> ("task_title", `String value) :: fields
      | None -> fields
    in
    let fields =
      match task_description with
      | Some value -> ("task_description", `String value) :: fields
      | None -> fields
    in
    `Assoc fields
  in
  let* result =
    dispatch_team_session_json_as ctx ~session_id ~requested_actor:request.actor
      ~tool_name:"masc_team_session_step" ~args
  in
  Ok
    (`Assoc
      [
        ("delegated_tool", `String "masc_team_session_step");
        ("result", result);
        ("actor", `String actor_for_session);
        ("operator_override", `Bool operator_override);
      ])

let execute_action (ctx : 'a context) (request : action_request) :
    (Yojson.Safe.t, string) result =
  match request.action_type with
  | "broadcast" ->
      let* () = validate_target_type "room" request in
      let message =
        match get_string_opt request.payload "message" with
        | Some value -> Ok value
        | None -> Error "payload.message is required"
      in
      let* message = message in
      let result = Room.broadcast ctx.config ~from_agent:request.actor ~content:message in
      Ok
        (`Assoc
          [
            ("delegated_tool", `String "masc_broadcast");
            ("result", `String result);
          ])
  | "room_pause" ->
      let* () = validate_target_type "room" request in
      let reason =
        get_string request.payload "reason" "Paused by operator control plane"
      in
      Room.pause ctx.config ~by:request.actor ~reason;
      Ok
        (`Assoc
          [
            ("delegated_tool", `String "masc_pause");
            ("result", `Assoc [ ("paused", `Bool true); ("reason", `String reason) ]);
          ])
  | "room_resume" ->
      let* () = validate_target_type "room" request in
      let status =
        match Room.resume ctx.config ~by:request.actor with
        | `Resumed -> "resumed"
        | `Already_running -> "already_running"
      in
      Ok
        (`Assoc
          [
            ("delegated_tool", `String "masc_resume");
            ("result", `Assoc [ ("status", `String status) ]);
          ])
  | "social_sweep" ->
      let* () = validate_target_type "room" request in
      if not Env_config.SocialRuntime.enabled then
        Ok
          (`Assoc
            [
              ("delegated_tool", `String "social_sweep");
              ( "result",
                `Assoc
                  [
                    ("checked", `Int 0);
                    ("acted", `Int 0);
                    ("passed", `Int 0);
                    ("skipped", `Int 1);
                    ("failed", `Int 0);
                    ("strategy", `String "event_driven");
                    ("queue_depth", `Int 0);
                    ("activity_report", `String "Social runtime is disabled");
                    ("last_system_skip_reason", `String "social runtime disabled");
                    ("checkins", `List []);
                  ] );
            ])
      else
        let summary_json, rows =
          Social_runtime.manual_sweep ~sw:ctx.sw ~clock:ctx.clock ~config:ctx.config
        in
        Ok
          (`Assoc
            [
              ("delegated_tool", `String "social_sweep");
              ( "result",
                merge_json_objects summary_json
                  (`Assoc [ ("checkins", `List rows) ]) );
            ])
  | "team_turn" ->
      let* () = validate_target_type "team_session" request in
      let* session_id = require_target_id request in
      let* turn_kind = parse_turn_kind request.payload in
      let message = get_string_opt request.payload "message" in
      let target_agent = get_string_opt request.payload "target_agent" in
      let task_title =
        match get_string_opt request.payload "task_title" with
        | Some value -> Some value
        | None -> get_string_opt request.payload "title"
      in
      let task_description =
        match get_string_opt request.payload "task_description" with
        | Some value -> Some value
        | None -> get_string_opt request.payload "description"
      in
      let task_priority = get_int request.payload "task_priority" (get_int request.payload "priority" 3) in
      execute_team_turn ~ctx ~request ~session_id ~turn_kind ~message ~target_agent
        ~task_title ~task_description ~task_priority
  | "team_note" ->
      let* () = validate_target_type "team_session" request in
      let* session_id = require_target_id request in
      let* message =
        require_payload_field request.payload "message" "payload.message is required"
      in
      execute_team_turn ~ctx ~request ~session_id
        ~turn_kind:Team_session_types.Turn_note ~message:(Some message)
        ~target_agent:None ~task_title:None ~task_description:None
        ~task_priority:3
  | "team_broadcast" ->
      let* () = validate_target_type "team_session" request in
      let* session_id = require_target_id request in
      let* message =
        require_payload_field request.payload "message" "payload.message is required"
      in
      execute_team_turn ~ctx ~request ~session_id
        ~turn_kind:Team_session_types.Turn_broadcast ~message:(Some message)
        ~target_agent:(get_string_opt request.payload "target_agent")
        ~task_title:None ~task_description:None ~task_priority:3
  | "team_task_inject" ->
      let* () = validate_target_type "team_session" request in
      let* session_id = require_target_id request in
      let task_title =
        match get_string_opt request.payload "task_title" with
        | Some value -> Ok value
        | None -> require_payload_field request.payload "title" "payload.task_title or payload.title is required"
      in
      let* task_title = task_title in
      let task_description =
        match get_string_opt request.payload "task_description" with
        | Some value -> Some value
        | None -> get_string_opt request.payload "description"
      in
      let task_priority = get_int request.payload "task_priority" (get_int request.payload "priority" 2) in
      execute_team_turn ~ctx ~request ~session_id
        ~turn_kind:Team_session_types.Turn_task
        ~message:(get_string_opt request.payload "message")
        ~target_agent:(get_string_opt request.payload "target_agent")
        ~task_title:(Some task_title) ~task_description ~task_priority
  | "team_worker_spawn_batch" ->
      let* () = validate_target_type "team_session" request in
      let* session_id = require_target_id request in
      let spawn_batch =
        match U.member "spawn_batch" request.payload with
        | `List [] -> Error "payload.spawn_batch must contain at least one item"
        | `List _ as xs -> Ok xs
        | _ -> Error "payload.spawn_batch is required"
      in
      let* spawn_batch = spawn_batch in
      let args =
        `Assoc
          [
            ("session_id", `String session_id);
            ("actor", `String request.actor);
            ("spawn_batch", spawn_batch);
          ]
      in
      let* result_json =
        dispatch_team_session_json_as ctx ~session_id ~requested_actor:request.actor
          ~tool_name:"masc_team_session_step" ~args
      in
      Ok
        (`Assoc
          [
            ("delegated_tool", `String "masc_team_session_step");
            ("result", result_json);
          ])
  | "team_stop" ->
      let* () = validate_target_type "team_session" request in
      let* session_id = require_target_id request in
      let reason =
        get_string request.payload "reason" "Stopped by operator control plane"
      in
      let generate_report = get_bool request.payload "generate_report" true in
      let* result =
        Team_session_engine_eio.stop_session ~config:ctx.config ~session_id
          ~reason ~generate_report
      in
      Ok
        (`Assoc
          [
            ("delegated_tool", `String "masc_team_session_stop");
            ("result", result);
          ])
  | "keeper_probe" ->
      let* () = validate_target_type "keeper" request in
      let* name = require_target_id request in
      let status_args =
        `Assoc
          [
            ("name", `String name);
            ("fast", `Bool false);
            ("include_context", `Bool false);
            ("include_metrics_overview", `Bool true);
            ("include_memory_bank", `Bool false);
            ("include_history_tail", `Bool false);
            ("include_compaction_history", `Bool false);
          ]
      in
      let* status_json =
        dispatch_keeper_json ctx ~tool_name:"masc_keeper_status" ~args:status_args
      in
      let diagnostic =
        match U.member "diagnostic" status_json with
        | `Assoc _ as json -> json
        | _ -> `Null
      in
      Ok
        (`Assoc
          [
            ("delegated_tool", `String "masc_keeper_status");
            ( "result",
              `Assoc
                [
                  ("status", status_json);
                  ("diagnostic", diagnostic);
                ] );
          ])
  | "keeper_recover" ->
      let* () = validate_target_type "keeper" request in
      let* name = require_target_id request in
      let status_args =
        `Assoc
          [
            ("name", `String name);
            ("fast", `Bool false);
            ("include_context", `Bool false);
            ("include_metrics_overview", `Bool true);
            ("include_memory_bank", `Bool false);
            ("include_history_tail", `Bool false);
            ("include_compaction_history", `Bool false);
          ]
      in
      let* before_status =
        dispatch_keeper_json ctx ~tool_name:"masc_keeper_status" ~args:status_args
      in
      let before_diagnostic =
        match U.member "diagnostic" before_status with
        | `Assoc _ as json -> json
        | _ -> `Null
      in
      let recoverable =
        match U.member "recoverable" before_diagnostic with
        | `Bool value -> value
        | _ -> false
      in
      if not recoverable then
        Ok
          (`Assoc
            [
              ("delegated_tool", `String "masc_keeper_recover");
              ( "result",
                `Assoc
                  [
                    ("recovered", `Bool false);
                    ("skipped_reason", `String "keeper is already healthy enough; recovery not required");
                    ("before", before_diagnostic);
                  ] );
            ])
      else
        let* down_result =
          dispatch_keeper_json ctx ~tool_name:"masc_keeper_down"
            ~args:(`Assoc [ ("name", `String name) ])
        in
        let* up_result =
          dispatch_keeper_json ctx ~tool_name:"masc_keeper_up"
            ~args:(`Assoc [ ("name", `String name) ])
        in
        let* after_status =
          dispatch_keeper_json ctx ~tool_name:"masc_keeper_status" ~args:status_args
        in
        let after_diagnostic =
          match U.member "diagnostic" after_status with
          | `Assoc _ as json -> json
          | _ -> `Null
        in
        let recovered, skipped_reason =
          keeper_recovery_outcome after_diagnostic
        in
        Ok
          (`Assoc
            [
              ("delegated_tool", `String "masc_keeper_recover");
              ( "result",
                `Assoc
                  [
                    ("recovered", `Bool recovered);
                    ( "skipped_reason",
                      match skipped_reason with
                      | Some reason -> `String reason
                      | None -> `Null );
                    ("before", before_diagnostic);
                    ("after", after_diagnostic);
                    ("down", down_result);
                    ("up", up_result);
                  ] );
            ])
  | "keeper_message" ->
      let* () = validate_target_type "keeper" request in
      let* name = require_target_id request in
      let message =
        match get_string_opt request.payload "message" with
        | Some value -> Ok value
        | None -> Error "payload.message is required"
      in
      let* message = message in
      let models =
        match request.payload |> U.member "models" with
        | `List items ->
            items
            |> List.filter_map (function
                   | `String value ->
                       let trimmed = String.trim value in
                       if trimmed = "" then None else Some (`String trimmed)
                   | _ -> None)
        | _ -> []
      in
      let args =
        `Assoc
          ([
             ("name", `String name);
             ("message", `String message);
           ]
          @ if models = [] then [] else [ ("models", `List models) ])
      in
      let keeper_ctx : _ Tool_keeper.context =
        {
          config = ctx.config;
          agent_name = ctx.agent_name;
          sw = ctx.sw;
          clock = ctx.clock;
          proc_mgr = ctx.proc_mgr;
        }
      in
      let* ok, body =
        match Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_msg" ~args with
        | Some (true, body) -> Ok (true, body)
        | Some (false, err) -> Error err
        | None -> Error "masc_keeper_msg dispatch unavailable"
      in
      let _ = ok in
      Ok
        (`Assoc
          [
            ("delegated_tool", `String "masc_keeper_msg");
            ("result", json_of_dispatch_output body);
          ])
  | "swarm_run_continue" ->
      let* () = validate_target_type "swarm_run" request in
      let swarm_json = swarm_run_json_for_request ctx request in
      let* swarm_json = swarm_json in
      let operation_id = swarm_run_operation_id swarm_json in
      let detachment_id = swarm_run_detachment_id swarm_json in
      let pending_decisions =
        swarm_json |> U.member "summary" |> U.member "pending_decisions"
        |> U.to_int_option |> Option.value ~default:0
      in
      if pending_decisions > 0 then
        Error "swarm run has pending approvals; resolve approvals before continue"
      else
        let steps =
          (match
             swarm_json |> U.member "operation" |> U.member "status"
             |> U.to_string_option
           with
          | Some "paused" -> [ ("masc_operation_resume", `Assoc [ ("operation_id", option_to_json (fun value -> `String value) operation_id) ]) ]
          | _ -> [])
          @
          (match operation_id, detachment_id with
          | Some value, _ ->
              [ ("masc_dispatch_tick", `Assoc [ ("operation_id", `String value) ]) ]
          | None, Some value ->
              [ ("masc_dispatch_tick", `Assoc [ ("detachment_id", `String value) ]) ]
          | None, None -> [])
        in
        if steps = [] then
          Error "swarm run has no resumable managed operation or detachment"
        else
          let* results =
            steps
            |> List.fold_left
                 (fun acc (tool_name, args) ->
                   let* collected = acc in
                   let* result_json =
                     dispatch_command_plane_json ctx ~tool_name ~args
                   in
                   Ok
                     (collected
                     @ [
                         `Assoc
                           [
                             ("tool", `String tool_name);
                             ("args", args);
                             ("result", result_json);
                           ];
                       ]))
                 (Ok [])
          in
          let run_id = Option.value ~default:"swarm-live" request.target_id in
          let reason =
            swarm_run_reason swarm_json
              "command-plane recovery chain executed for swarm-live run"
          in
          let resolution =
            Command_plane_v2.record_swarm_run_resolution_json ctx.config ~run_id
              ~status:"continued" ~actor:request.actor ~reason ?operation_id
              ?detachment_id
              ?note:(Some "operator continue chain executed") ()
          in
          Ok
            (`Assoc
              [
                ("delegated_tool", `String "swarm_run_continue_chain");
                ("delegated_tools", `List (List.map (fun (tool_name, _) -> `String tool_name) steps));
                ("result", `List results);
                ("resolution", resolution);
              ])
  | "swarm_run_rerun" ->
      let* () = validate_target_type "swarm_run" request in
      let swarm_json = swarm_run_json_for_request ctx request in
      let* swarm_json = swarm_json in
      let run_id = Option.value ~default:"swarm-live" request.target_id in
      let args = `Assoc [ ("run_id", `String run_id) ] in
      let* rerun_result =
        dispatch_command_plane_json ctx ~tool_name:"masc_swarm_live_run" ~args
      in
      let resolution =
        Command_plane_v2.record_swarm_run_resolution_json ctx.config ~run_id
          ~status:"rerun" ~actor:request.actor
          ~reason:
            (swarm_run_reason swarm_json
               "swarm-live harness rerun requested through operator control")
          ?operation_id:(swarm_run_operation_id swarm_json)
          ?detachment_id:(swarm_run_detachment_id swarm_json)
          ?note:(Some "operator rerun executed") ()
      in
      Ok
        (`Assoc
          [
            ("delegated_tool", `String "masc_swarm_live_run");
            ("delegated_tools", `List [ `String "masc_swarm_live_run" ]);
            ("result", rerun_result);
            ("resolution", resolution);
          ])
  | "swarm_run_abandon" ->
      let* () = validate_target_type "swarm_run" request in
      let swarm_json = swarm_run_json_for_request ctx request in
      let* swarm_json = swarm_json in
      let run_id = Option.value ~default:"swarm-live" request.target_id in
      let resolution =
        Command_plane_v2.record_swarm_run_resolution_json ctx.config ~run_id
          ~status:"abandoned" ~actor:request.actor
          ~reason:
            (get_string request.payload "reason"
               (swarm_run_reason swarm_json
                  "swarm-live run was soft-abandoned by operator"))
          ?operation_id:(swarm_run_operation_id swarm_json)
          ?detachment_id:(swarm_run_detachment_id swarm_json)
          ?note:(Some "soft abandon; no operation stop issued") ()
      in
      Ok
        (`Assoc
          [
            ("delegated_tool", `String "swarm_run_resolution");
            ("delegated_tools", `List []);
            ("result", `Assoc [ ("recorded", `Bool true) ]);
            ("resolution", resolution);
          ])
  | "task_inject" ->
      let* () = validate_target_type "room" request in
      let title =
        match get_string_opt request.payload "title" with
        | Some value -> Ok value
        | None -> Error "payload.title is required"
      in
      let* title = title in
      let priority = get_int request.payload "priority" 2 in
      let description =
        get_string request.payload "description" "Injected by operator control plane"
      in
      let result = Room.add_task ctx.config ~title ~priority ~description in
      Ok
        (`Assoc
          [
            ("delegated_tool", `String "masc_add_task");
            ("result", `String result);
          ])
  | "" -> Error "action_type is required"
  | other -> Error (Printf.sprintf "unsupported action_type: %s" other)

let validate_request request =
  match request.action_type with
  | "broadcast" | "room_pause" | "room_resume" | "social_sweep" | "lodge_tick"
  | "team_turn" | "team_note"
  | "team_broadcast" | "team_task_inject" | "team_worker_spawn_batch"
  | "team_stop"
  | "keeper_message" | "keeper_probe" | "keeper_recover"
  | "swarm_run_continue" | "swarm_run_rerun" | "swarm_run_abandon"
  | "task_inject" ->
      Ok ()
  | "" -> Error "action_type is required"
  | other -> Error (Printf.sprintf "unsupported action_type: %s" other)

let action_json ?actor_hint (ctx : _ context) args :
    (Yojson.Safe.t, string) result =
  let* request = action_request_of_args ?actor_hint ctx args in
  let* () = validate_request request in
  let delegated_tool = delegated_tool_for request.action_type in
  let trace_id = trace_id "ops" in
  let started_at = Unix.gettimeofday () in
  if confirm_required request.action_type then (
    let expires_at = iso_of_unix (Unix.gettimeofday () +. remote_confirm_ttl_seconds) in
    let* token = generate_confirm_token ~clock:ctx.clock ctx.config in
    let preview =
      match request.action_type with
      | "swarm_run_continue" | "swarm_run_rerun" | "swarm_run_abandon" -> (
          match swarm_run_json_for_request ctx request with
          | Ok swarm_json -> swarm_run_chain_preview request swarm_json
          | Error _ -> preview_of_action request)
      | _ -> preview_of_action request
    in
    let entry =
      {
        token;
        trace_id;
        actor = request.actor;
        action_type = request.action_type;
        target_type = request.target_type;
        target_id = request.target_id;
        payload = request.payload;
        delegated_tool;
        created_at = Types.now_iso ();
        expires_at = Some expires_at;
      }
    in
    upsert_pending_confirm ctx.config entry;
    append_action_log ctx.config
      {
        trace_id;
        actor = request.actor;
        remote_session_id = ctx.mcp_session_id;
        remote_client_type = remote_client_type_of_context ctx;
        action_type = request.action_type;
        target_type = request.target_type;
        target_id = request.target_id;
        delegated_tool;
        confirmation_state = "preview";
        result_status = "ok";
        latency_ms = 0;
        created_at = Types.now_iso ();
      };
    Ok
      (json_ok
         [
           ("trace_id", `String trace_id);
           ("confirm_required", `Bool true);
           ("confirm_token", `String entry.token);
           ("preview", preview);
           ("delegated_tool", `String delegated_tool);
           ("expires_at", `String expires_at);
         ]))
  else
    let* executed = execute_action ctx request in
    let latency_ms = int_of_float ((Unix.gettimeofday () -. started_at) *. 1000.0) in
    append_action_log ctx.config
      {
        trace_id;
        actor = request.actor;
        remote_session_id = ctx.mcp_session_id;
        remote_client_type = remote_client_type_of_context ctx;
        action_type = request.action_type;
        target_type = request.target_type;
        target_id = request.target_id;
        delegated_tool;
        confirmation_state = "immediate";
        result_status = "ok";
        latency_ms;
        created_at = Types.now_iso ();
      };
    Ok
      (json_ok
         [
           ("trace_id", `String trace_id);
           ("confirm_required", `Bool false);
           ("delegated_tool", `String delegated_tool);
           ("result", executed);
         ])

let confirm_json ?actor_hint (ctx : _ context) args :
    (Yojson.Safe.t, string) result =
  let* actor = resolved_actor_for_args ?actor_hint ctx args in
  let decision =
    match get_string_opt args "decision" with
    | Some raw ->
        let normalized = String.lowercase_ascii (String.trim raw) in
        if normalized = "" then "confirm" else normalized
    | None -> "confirm"
  in
  match get_string_opt args "confirm_token" with
  | None -> Error "confirm_token is required"
  | Some confirm_token -> (
      match
        raw_pending_confirms ctx.config
        |> List.find_opt (fun entry -> String.equal entry.token confirm_token)
      with
      | None -> Error "pending confirmation not found"
      | Some entry when pending_confirm_expired entry ->
          remove_pending_confirm ctx.config confirm_token;
          append_action_log ctx.config
            {
              trace_id = entry.trace_id;
              actor;
              remote_session_id = ctx.mcp_session_id;
              remote_client_type = remote_client_type_of_context ctx;
              action_type = entry.action_type;
              target_type = entry.target_type;
              target_id = entry.target_id;
              delegated_tool = entry.delegated_tool;
              confirmation_state = "expired";
              result_status = "error";
              latency_ms = 0;
              created_at = Types.now_iso ();
            };
          Error "pending confirmation expired"
      | Some entry when not (String.equal actor entry.actor) ->
          append_action_log ctx.config
            {
              trace_id = entry.trace_id;
              actor;
              remote_session_id = ctx.mcp_session_id;
              remote_client_type = remote_client_type_of_context ctx;
              action_type = entry.action_type;
              target_type = entry.target_type;
              target_id = entry.target_id;
              delegated_tool = entry.delegated_tool;
              confirmation_state = "denied";
              result_status = "error";
              latency_ms = 0;
              created_at = Types.now_iso ();
            };
          Error "actor is not allowed to confirm this action"
      | Some entry ->
          if String.equal decision "deny" then (
            remove_pending_confirm ctx.config confirm_token;
            append_action_log ctx.config
              {
                trace_id = entry.trace_id;
                actor;
                remote_session_id = ctx.mcp_session_id;
                remote_client_type = remote_client_type_of_context ctx;
                action_type = entry.action_type;
                target_type = entry.target_type;
                target_id = entry.target_id;
                delegated_tool = entry.delegated_tool;
                confirmation_state = "denied";
                result_status = "ok";
                latency_ms = 0;
                created_at = Types.now_iso ();
              };
            Ok
              (json_ok
                 [
                   ("trace_id", `String entry.trace_id);
                   ("decision", `String "deny");
                   ("executed_action", pending_confirm_to_yojson entry);
                 ]))
          else
            let started_at = Unix.gettimeofday () in
            let request =
              {
                actor = entry.actor;
                action_type = entry.action_type;
                target_type = entry.target_type;
                target_id = entry.target_id;
                payload = entry.payload;
              }
            in
            let* executed = execute_action ctx request in
            remove_pending_confirm ctx.config confirm_token;
            let latency_ms = int_of_float ((Unix.gettimeofday () -. started_at) *. 1000.0) in
            append_action_log ctx.config
              {
                trace_id = entry.trace_id;
                actor = entry.actor;
                remote_session_id = ctx.mcp_session_id;
                remote_client_type = remote_client_type_of_context ctx;
                action_type = entry.action_type;
                target_type = entry.target_type;
                target_id = entry.target_id;
                delegated_tool = entry.delegated_tool;
                confirmation_state = "confirmed";
                result_status = "ok";
                latency_ms;
                created_at = Types.now_iso ();
              };
            Ok
              (json_ok
                 [
                   ("trace_id", `String entry.trace_id);
                   ("decision", `String "confirm");
                   ("executed_action", pending_confirm_to_yojson entry);
                   ("delegated_tool_result", executed);
                 ]))
