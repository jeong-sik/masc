module U = Yojson.Safe.Util
open Tool_args

let ( let* ) = Result.bind

type 'a context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  mcp_session_id : string option;
}

type pending_confirm = {
  token : string;
  trace_id : string;
  actor : string;
  action_type : string;
  target_type : string;
  target_id : string option;
  payload : Yojson.Safe.t;
  delegated_tool : string;
  created_at : string;
  expires_at : string option;
}

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

let option_to_json f = function
  | Some value -> f value
  | None -> `Null

let string_option_to_json = option_to_json (fun value -> `String value)

let normalized_actor ~context_actor = function
  | Some raw when String.trim raw <> "" -> String.trim raw
  | _ ->
      let trimmed = String.trim context_actor in
      if trimmed = "" || String.equal trimmed "unknown" then "dashboard" else trimmed

let operator_dir config =
  Filename.concat (Room.masc_dir config) "operator"

let pending_confirms_path config =
  Filename.concat (operator_dir config) "pending_confirms.json"

let action_log_path config =
  Filename.concat (operator_dir config) "action_log.jsonl"

let remote_confirm_ttl_seconds = 900.0

let trace_id prefix =
  let entropy =
    Printf.sprintf "%s|%d|%.6f|%d"
      prefix (Unix.getpid ()) (Unix.gettimeofday ()) (Random.bits ())
  in
  let digest = Digestif.SHA256.(digest_string entropy |> to_hex) in
  prefix ^ "_" ^ String.sub digest 0 16

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

let resident_judge_runtime_json (config : Room.config) =
  let runtime = Dashboard_operator_judge.runtime_status config.base_path in
  `Assoc
    [
      ("enabled", `Bool runtime.enabled);
      ("judge_online", `Bool runtime.judge_online);
      ("refreshing", `Bool runtime.refreshing);
      ("generated_at", string_option_to_json runtime.generated_at);
      ("expires_at", string_option_to_json runtime.expires_at);
      ("model_used", string_option_to_json runtime.model_used);
      ("keeper_name", `String runtime.keeper_name);
      ("last_error", string_option_to_json runtime.last_error);
    ]

let operator_surface_contract_json =
  `Assoc
    [
      ("command_plane", `String "truth");
      ("judgment", `String "judgment");
      ("swarm_status", `String "derived");
      ("attention_items", `String "derived");
      ("recommended_actions", `String "fallback");
      ("active_recommended_actions", `String "judgment_or_fallback");
      ("session_cards", `String "derived");
      ("worker_cards", `String "truth");
    ]

type attention_item = {
  kind : string;
  severity : string;
  summary : string;
  target_type : string;
  target_id : string option;
  actor : string option;
  evidence : Yojson.Safe.t;
}

type recommended_action = {
  action_type : string;
  target_type : string;
  target_id : string option;
  severity : string;
  reason : string;
  suggested_payload : Yojson.Safe.t;
}

type worker_card = {
  actor : string option;
  spawn_agent : string option;
  spawn_role : string option;
  spawn_model : string option;
  worker_class : string option;
  parent_actor : string option;
  capsule_mode : string option;
  runtime_pool : string option;
  lane_id : string option;
  controller_level : string option;
  control_domain : string option;
  supervisor_actor : string option;
  model_tier : string option;
  task_profile : string option;
  risk_level : string option;
  routing_confidence : float option;
  routing_reason : string option;
  status : string;
  turn_count : int;
  empty_note_turn_count : int;
  has_turn : bool;
  last_turn_ts_iso : string option;
}

type session_digest = {
  session_id : string;
  goal : string;
  status : string;
  health : string;
  scale_profile : string;
  planned_worker_count : int;
  active_agent_count : int;
  last_turn_age_sec : int option;
  control_profile : string;
  worker_class_counts : Yojson.Safe.t;
  runtime_pool_counts : Yojson.Safe.t;
  lane_counts : Yojson.Safe.t;
  controller_counts : Yojson.Safe.t;
  control_domain_counts : Yojson.Safe.t;
  tier_counts : Yojson.Safe.t;
  task_profile_counts : Yojson.Safe.t;
  escalation_count : int;
  controller_tree : Yojson.Safe.t;
  lane_health : Yojson.Safe.t;
  confidence_heatmap : Yojson.Safe.t;
  context_pressure_by_lane : Yojson.Safe.t;
  intervention_counters : Yojson.Safe.t;
  local_runtime : Yojson.Safe.t;
  attention_items : attention_item list;
  recommended_actions : recommended_action list;
  worker_cards : worker_card list;
}

let stalled_session_threshold_sec = 300.0
let planned_worker_turn_grace_sec = 180.0
let room_digest_session_limit = 10

let preview_of_pending_confirm (entry : pending_confirm) =
  `Assoc
    [
      ("trace_id", `String entry.trace_id);
      ("actor", `String entry.actor);
      ("action_type", `String entry.action_type);
      ("target_type", `String entry.target_type);
      ("target_id", string_option_to_json entry.target_id);
      ("payload", entry.payload);
    ]

let pending_confirm_to_yojson (entry : pending_confirm) =
  `Assoc
    [
      ("token", `String entry.token);
      ("confirm_token", `String entry.token);
      ("trace_id", `String entry.trace_id);
      ("actor", `String entry.actor);
      ("action_type", `String entry.action_type);
      ("target_type", `String entry.target_type);
      ("target_id", string_option_to_json entry.target_id);
      ("payload", entry.payload);
      ("delegated_tool", `String entry.delegated_tool);
      ("created_at", `String entry.created_at);
      ("expires_at", string_option_to_json entry.expires_at);
      ("preview", preview_of_pending_confirm entry);
    ]

let pending_confirm_of_yojson json =
  try
    let token = json |> U.member "token" |> U.to_string in
    let trace_id =
      match json |> U.member "trace_id" |> U.to_string_option with
      | Some value -> value
      | None -> trace_id "opc"
    in
    let actor = json |> U.member "actor" |> U.to_string in
    let action_type = json |> U.member "action_type" |> U.to_string in
    let target_type = json |> U.member "target_type" |> U.to_string in
    let target_id = json |> U.member "target_id" |> U.to_string_option in
    let payload =
      match json |> U.member "payload" with
      | `Assoc _ as payload -> payload
      | _ -> `Assoc []
    in
    let delegated_tool = json |> U.member "delegated_tool" |> U.to_string in
    let created_at = json |> U.member "created_at" |> U.to_string in
    let expires_at = json |> U.member "expires_at" |> U.to_string_option in
    Ok
      {
        token;
        trace_id;
        actor;
        action_type;
        target_type;
        target_id;
        payload;
        delegated_tool;
        created_at;
        expires_at;
      }
  with U.Type_error (msg, _) | Failure msg -> Error msg

let raw_pending_confirms config : pending_confirm list =
  match Room_utils.read_json_opt config (pending_confirms_path config) with
  | None -> []
  | Some (`List entries) ->
      List.filter_map
        (fun json ->
          match pending_confirm_of_yojson json with
          | Ok entry -> Some entry
          | Error _ -> None)
        entries
  | Some _ -> []

let write_pending_confirms config (entries : pending_confirm list) =
  Room_utils.write_json config (pending_confirms_path config)
    (`List (List.map pending_confirm_to_yojson entries))

let pending_confirm_expired (entry : pending_confirm) =
  match entry.expires_at with
  | Some exp -> Types.now_iso () > exp
  | None -> false

let read_pending_confirms config : pending_confirm list =
  let entries = raw_pending_confirms config in
  let active = List.filter (fun entry -> not (pending_confirm_expired entry)) entries in
  if List.length active <> List.length entries then write_pending_confirms config active;
  active

let upsert_pending_confirm config entry =
  let remaining =
    read_pending_confirms config
    |> List.filter (fun existing -> not (String.equal existing.token entry.token))
  in
  write_pending_confirms config (entry :: remaining)

let remove_pending_confirm config token =
  let remaining =
    read_pending_confirms config
    |> List.filter (fun existing -> not (String.equal existing.token token))
  in
  write_pending_confirms config remaining

let pending_confirms_json ?actor config =
  let actor_filter =
    match actor with
    | Some raw ->
        let trimmed = String.trim raw in
        if trimmed = "" then None else Some trimmed
    | None -> None
  in
  let rows : pending_confirm list =
    read_pending_confirms config
    |> List.filter (fun (entry : pending_confirm) ->
           match actor_filter with
           | None -> true
           | Some value -> String.equal value entry.actor)
    |> List.sort (fun (a : pending_confirm) (b : pending_confirm) ->
           String.compare b.created_at a.created_at)
  in
  `List (List.map pending_confirm_to_yojson rows)

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

type available_action = {
  action_type : string;
  target_type : string;
  description : string;
  confirm_required : bool;
}

let available_actions : available_action list =
  [
    {
      action_type = "broadcast";
      target_type = "room";
      description = "Use this when you need a room-wide operator broadcast.";
      confirm_required = false;
    };
    {
      action_type = "room_pause";
      target_type = "room";
      description = "Use this when you need to pause room automation or spawning.";
      confirm_required = true;
    };
    {
      action_type = "room_resume";
      target_type = "room";
      description = "Use this when you need to resume a paused room.";
      confirm_required = false;
    };
    {
      action_type = "lodge_tick";
      target_type = "room";
      description = "Use this when you need to run one immediate Lodge tick and inspect which agents acted or were skipped.";
      confirm_required = false;
    };
    {
      action_type = "task_inject";
      target_type = "room";
      description = "Use this when you need to inject a new backlog task into the room through a preview-confirm path.";
      confirm_required = true;
    };
    {
      action_type = "team_note";
      target_type = "team_session";
      description = "Use this when you need to append a non-broadcast operator note to a team session.";
      confirm_required = false;
    };
    {
      action_type = "team_broadcast";
      target_type = "team_session";
      description = "Use this when you need a broadcast-style orchestration turn in a team session.";
      confirm_required = false;
    };
    {
      action_type = "team_task_inject";
      target_type = "team_session";
      description = "Use this when you need to inject a new task into a running team session.";
      confirm_required = true;
    };
    {
      action_type = "team_worker_spawn_batch";
      target_type = "team_session";
      description = "Use this when you need to spawn or replace one or more team-session workers through a preview-confirm path.";
      confirm_required = true;
    };
    {
      action_type = "team_stop";
      target_type = "team_session";
      description = "Use this when you need to stop a running team session.";
      confirm_required = true;
    };
    {
      action_type = "keeper_message";
      target_type = "keeper";
      description = "Use this when you need to send a direct operator message to a keeper.";
      confirm_required = false;
    };
    {
      action_type = "keeper_probe";
      target_type = "keeper";
      description = "Use this when you need an immediate keeper diagnostic snapshot with health, silence reason, and next suggested action.";
      confirm_required = false;
    };
    {
      action_type = "keeper_recover";
      target_type = "keeper";
      description = "Use this when a keeper is stale, degraded, or offline and you need a safe down/up recovery with before-and-after diagnostics.";
      confirm_required = false;
    };
    {
      action_type = "swarm_run_continue";
      target_type = "swarm_run";
      description = "Use this when a stalled swarm-live run still has resumable managed state and you want a preview-confirm command-plane recovery chain.";
      confirm_required = true;
    };
    {
      action_type = "swarm_run_rerun";
      target_type = "swarm_run";
      description = "Use this when a swarm-live run has no trustworthy resumable state and you want to rerun the harness for the same run_id.";
      confirm_required = true;
    };
    {
      action_type = "swarm_run_abandon";
      target_type = "swarm_run";
      description = "Use this when you want to soft-abandon a swarm-live run without stopping any matched operation.";
      confirm_required = true;
    };
  ]

let available_action_to_yojson (entry : available_action) =
  `Assoc
    [
      ("action_type", `String entry.action_type);
      ("target_type", `String entry.target_type);
      ("description", `String entry.description);
      ("confirm_required", `Bool entry.confirm_required);
    ]

let available_actions_json =
  `List (List.map available_action_to_yojson available_actions)

let pending_confirm_summary_json ?actor config =
  let actor_filter =
    match actor with
    | Some raw ->
        let trimmed = String.trim raw in
        if trimmed = "" then None else Some trimmed
    | None -> None
  in
  let all_entries =
    read_pending_confirms config
    |> List.sort (fun (a : pending_confirm) (b : pending_confirm) ->
           String.compare b.created_at a.created_at)
  in
  let visible_entries =
    match actor_filter with
    | None -> all_entries
    | Some value ->
        List.filter (fun (entry : pending_confirm) -> String.equal value entry.actor) all_entries
  in
  let hidden_entries =
    match actor_filter with
    | None -> []
    | Some value ->
        List.filter (fun (entry : pending_confirm) -> not (String.equal value entry.actor)) all_entries
  in
  let hidden_actors =
    hidden_entries
    |> List.map (fun (entry : pending_confirm) -> entry.actor)
    |> List.sort_uniq String.compare
    |> List.map (fun value -> `String value)
  in
  let confirm_required_actions =
    available_actions
    |> List.filter (fun (entry : available_action) -> entry.confirm_required)
    |> List.map available_action_to_yojson
  in
  `Assoc
    [
      ("actor_filter", string_option_to_json actor_filter);
      ("filter_active", `Bool (Option.is_some actor_filter));
      ("visible_count", `Int (List.length visible_entries));
      ("total_count", `Int (List.length all_entries));
      ("hidden_count", `Int (List.length hidden_entries));
      ("hidden_actors", `List hidden_actors);
      ("confirm_required_actions", `List confirm_required_actions);
    ]

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
  let fallback_count =
    if fallback_latest = [] then None else Some (List.length fallback_latest)
  in
  let fallback_source =
    if fallback_latest <> [] then Some "keeper_metrics" else Some "keeper_policy"
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
        (task.allowed_tools, [], None, Some "heartbeat_task", Some task.created_at)
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

let keepers_json config =
  let names = Keeper_types.resident_keeper_names config in
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
            let diagnostic =
              Keeper_exec_status.keeper_diagnostic_json ~meta
                ~agent_status:agent_json ~keepalive_running ~history_items:[]
                ~now_ts:(Time_compat.now ())
            in
            let allowed_tool_names, latest_tool_names, latest_tool_call_count,
                tool_audit_source, tool_audit_at =
              keeper_tool_audit_fields config meta
            in
            let agent_status =
              if not agent_exists then "offline"
              else
                match agent_json |> U.member "status" with
                | `String status -> status
                | _ -> "unknown"
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
                ]))
      names
  in
  `Assoc [ ("count", `Int (List.length rows)); ("items", `List rows) ]

let persistent_agents_json config =
  let names = Keeper_types.persistent_agent_names config in
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

let severity_rank = function
  | "bad" -> 2
  | "warn" -> 1
  | _ -> 0

let compare_attention (a : attention_item) (b : attention_item) =
  let by_severity = Int.compare (severity_rank b.severity) (severity_rank a.severity) in
  if by_severity <> 0 then by_severity
  else
    match (a.target_id, b.target_id) with
    | Some x, Some y ->
        let by_target = String.compare x y in
        if by_target <> 0 then by_target else String.compare a.kind b.kind
    | Some _, None -> -1
    | None, Some _ -> 1
    | None, None -> String.compare a.kind b.kind

let compare_recommendation (a : recommended_action) (b : recommended_action) =
  let by_severity = Int.compare (severity_rank b.severity) (severity_rank a.severity) in
  if by_severity <> 0 then by_severity
  else
    match (a.target_id, b.target_id) with
    | Some x, Some y ->
        let by_target = String.compare x y in
        if by_target <> 0 then by_target else String.compare a.action_type b.action_type
    | Some _, None -> -1
    | None, Some _ -> 1
    | None, None -> String.compare a.action_type b.action_type

let compare_worker_card (a : worker_card) (b : worker_card) =
  let by_status = String.compare a.status b.status in
  if by_status <> 0 then by_status
  else
    let by_turns = Int.compare b.turn_count a.turn_count in
    if by_turns <> 0 then by_turns
    else
      String.compare
        (Option.value ~default:"" a.actor)
        (Option.value ~default:"" b.actor)

let compare_session_digest (a : session_digest) (b : session_digest) =
  let by_health = Int.compare (severity_rank b.health) (severity_rank a.health) in
  if by_health <> 0 then by_health
  else
    let by_status =
      match (a.status, b.status) with
      | "running", "running" -> 0
      | "running", _ -> -1
      | _, "running" -> 1
      | _ -> String.compare a.status b.status
    in
    if by_status <> 0 then by_status else String.compare a.session_id b.session_id

let attention_item_to_yojson (item : attention_item) =
  `Assoc
    [
      ("kind", `String item.kind);
      ("severity", `String item.severity);
      ("summary", `String item.summary);
      ("target_type", `String item.target_type);
      ("target_id", string_option_to_json item.target_id);
      ("actor", string_option_to_json item.actor);
      ("evidence", item.evidence);
      ("provenance", `String "derived");
      ("decision_engine", `String "deterministic_translation");
      ("authoritative", `Bool false);
    ]

let recommended_confirm_required = function
  | "room_pause" | "team_stop" | "task_inject" | "team_task_inject"
  | "team_worker_spawn_batch" | "swarm_run_continue"
  | "swarm_run_rerun" | "swarm_run_abandon" ->
      true
  | _ -> false

let recommended_action_to_yojson ~actor (item : recommended_action) =
  let preview =
    `Assoc
      [
        ("actor", `String actor);
        ("action_type", `String item.action_type);
        ("target_type", `String item.target_type);
        ("target_id", string_option_to_json item.target_id);
        ("payload", item.suggested_payload);
      ]
  in
  `Assoc
    [
      ("action_type", `String item.action_type);
      ("target_type", `String item.target_type);
      ("target_id", string_option_to_json item.target_id);
      ("severity", `String item.severity);
      ("reason", `String item.reason);
      ("confirm_required", `Bool (recommended_confirm_required item.action_type));
      ("suggested_payload", item.suggested_payload);
      ("preview", preview);
      ("provenance", `String "fallback");
      ("decision_engine", `String "deterministic_rules");
      ("authoritative", `Bool false);
    ]

let worker_card_to_yojson (card : worker_card) =
  `Assoc
    [
      ("actor", string_option_to_json card.actor);
      ("spawn_agent", string_option_to_json card.spawn_agent);
      ("spawn_role", string_option_to_json card.spawn_role);
      ("spawn_model", string_option_to_json card.spawn_model);
      ("worker_class", string_option_to_json card.worker_class);
      ("parent_actor", string_option_to_json card.parent_actor);
      ("capsule_mode", string_option_to_json card.capsule_mode);
      ("runtime_pool", string_option_to_json card.runtime_pool);
      ("lane_id", string_option_to_json card.lane_id);
      ("controller_level", string_option_to_json card.controller_level);
      ("control_domain", string_option_to_json card.control_domain);
      ("supervisor_actor", string_option_to_json card.supervisor_actor);
      ("model_tier", string_option_to_json card.model_tier);
      ("task_profile", string_option_to_json card.task_profile);
      ("risk_level", string_option_to_json card.risk_level);
      ( "routing_confidence",
        option_to_json (fun value -> `Float value) card.routing_confidence );
      ("routing_reason", string_option_to_json card.routing_reason);
      ("status", `String card.status);
      ("turn_count", `Int card.turn_count);
      ("empty_note_turn_count", `Int card.empty_note_turn_count);
      ("has_turn", `Bool card.has_turn);
      ("last_turn_ts_iso", string_option_to_json card.last_turn_ts_iso);
      ("provenance", `String "truth");
      ("authoritative", `Bool true);
    ]

let spawn_batch_stub_of_cards (cards : worker_card list) =
  let items =
    cards
    |> List.filter_map (fun (card : worker_card) ->
           match card.spawn_agent with
           | None -> None
           | Some spawn_agent ->
               let label =
                 match (card.spawn_role, card.actor) with
                 | Some role, _ when String.trim role <> "" -> role
                 | _, Some actor when String.trim actor <> "" -> actor
                 | _ -> spawn_agent
               in
               let fields =
                 [
                   ("spawn_agent", `String spawn_agent);
                   ( "spawn_prompt",
                     `String
                       (Printf.sprintf
                          "REQUIRED: provide explicit spawn_prompt for replacement worker %s"
                          label) );
                 ]
               in
               let fields =
                 match card.spawn_role with
                 | Some role when String.trim role <> "" ->
                     ("spawn_role", `String role) :: fields
                 | _ -> fields
               in
               let fields =
                 match card.spawn_model with
                 | Some model when String.trim model <> "" ->
                     ("spawn_model", `String model) :: fields
                 | _ -> fields
               in
               let fields =
                 match card.worker_class with
                 | Some worker_class when String.trim worker_class <> "" ->
                     ("worker_class", `String worker_class) :: fields
                 | _ -> fields
               in
               let fields =
                 match card.parent_actor with
                 | Some parent_actor when String.trim parent_actor <> "" ->
                     ("parent_actor", `String parent_actor) :: fields
                 | _ -> fields
               in
               let fields =
                 match card.capsule_mode with
                 | Some capsule_mode when String.trim capsule_mode <> "" ->
                     ("capsule_mode", `String capsule_mode) :: fields
                 | _ -> fields
               in
               let fields =
                 match card.runtime_pool with
                 | Some runtime_pool when String.trim runtime_pool <> "" ->
                     ("runtime_pool", `String runtime_pool) :: fields
                 | _ -> fields
               in
               let fields =
                 match card.lane_id with
                 | Some lane_id when String.trim lane_id <> "" ->
                     ("lane_id", `String lane_id) :: fields
                 | _ -> fields
               in
               let fields =
                 match card.control_domain with
                 | Some control_domain when String.trim control_domain <> "" ->
                     ("control_domain", `String control_domain) :: fields
                 | _ -> fields
               in
               let fields =
                 match card.supervisor_actor with
                 | Some supervisor_actor when String.trim supervisor_actor <> "" ->
                     ("supervisor_actor", `String supervisor_actor) :: fields
                 | _ -> fields
               in
               let fields =
                 match card.model_tier with
                 | Some model_tier when String.trim model_tier <> "" ->
                     ("model_tier", `String model_tier) :: fields
                 | _ -> fields
               in
               let fields =
                 match card.task_profile with
                 | Some task_profile when String.trim task_profile <> "" ->
                     ("task_profile", `String task_profile) :: fields
                 | _ -> fields
               in
               let fields =
                 match card.risk_level with
                 | Some risk_level when String.trim risk_level <> "" ->
                     ("risk_level", `String risk_level) :: fields
                 | _ -> fields
               in
               Some (`Assoc (List.rev fields)))
  in
  `Assoc [ ("spawn_batch", `List items) ]

let aggregate_worker_class_counts (sessions : Team_session_types.session list) =
  sessions
  |> List.concat_map (fun (session : Team_session_types.session) -> session.planned_workers)
  |> Team_session_types.worker_class_counts
  |> Team_session_types.counts_to_json

let aggregate_runtime_pool_counts (sessions : Team_session_types.session list) =
  sessions
  |> List.concat_map (fun (session : Team_session_types.session) -> session.planned_workers)
  |> Team_session_types.runtime_pool_counts
  |> Team_session_types.counts_to_json

let aggregate_lane_counts (sessions : Team_session_types.session list) =
  sessions
  |> List.concat_map (fun (session : Team_session_types.session) -> session.planned_workers)
  |> Team_session_types.lane_counts
  |> Team_session_types.counts_to_json

let aggregate_controller_counts (sessions : Team_session_types.session list) =
  sessions
  |> List.concat_map (fun (session : Team_session_types.session) -> session.planned_workers)
  |> Team_session_types.controller_level_counts
  |> Team_session_types.counts_to_json

let aggregate_control_domain_counts (sessions : Team_session_types.session list) =
  sessions
  |> List.concat_map (fun (session : Team_session_types.session) -> session.planned_workers)
  |> Team_session_types.control_domain_counts
  |> Team_session_types.counts_to_json

let aggregate_tier_counts (sessions : Team_session_types.session list) =
  sessions
  |> List.concat_map (fun (session : Team_session_types.session) -> session.planned_workers)
  |> Team_session_types.model_tier_counts
  |> Team_session_types.counts_to_json

let aggregate_task_profile_counts (sessions : Team_session_types.session list) =
  sessions
  |> List.concat_map (fun (session : Team_session_types.session) -> session.planned_workers)
  |> Team_session_types.task_profile_counts
  |> Team_session_types.counts_to_json

let aggregate_escalation_count (sessions : Team_session_types.session list) =
  sessions
  |> List.concat_map (fun (session : Team_session_types.session) -> session.planned_workers)
  |> Team_session_types.escalation_count

let aggregated_local_runtime_json (sessions : Team_session_types.session list) =
  if
    List.exists
      (fun (session : Team_session_types.session) ->
        session.scale_profile = Team_session_types.Scale_local64)
      sessions
  then Tool_llama.runtime_status_json ()
  else `Null

let session_card_to_yojson ~actor (digest : session_digest) =
  let top_attention =
    match digest.attention_items |> List.sort compare_attention with
    | item :: _ -> Some item
    | [] -> None
  in
  let top_recommendation =
    match digest.recommended_actions |> List.sort compare_recommendation with
    | item :: _ -> Some item
    | [] -> None
  in
  `Assoc
    [
      ("session_id", `String digest.session_id);
      ("goal", `String digest.goal);
      ("status", `String digest.status);
      ("health", `String digest.health);
      ("scale_profile", `String digest.scale_profile);
      ("control_profile", `String digest.control_profile);
      ("planned_worker_count", `Int digest.planned_worker_count);
      ("active_agent_count", `Int digest.active_agent_count);
      ("last_turn_age_sec", option_to_json (fun v -> `Int v) digest.last_turn_age_sec);
      ("worker_class_counts", digest.worker_class_counts);
      ("runtime_pool_counts", digest.runtime_pool_counts);
      ("lane_counts", digest.lane_counts);
      ("controller_counts", digest.controller_counts);
      ("control_domain_counts", digest.control_domain_counts);
      ("tier_counts", digest.tier_counts);
      ("task_profile_counts", digest.task_profile_counts);
      ("escalation_count", `Int digest.escalation_count);
      ("controller_tree", digest.controller_tree);
      ("lane_health", digest.lane_health);
      ("confidence_heatmap", digest.confidence_heatmap);
      ("context_pressure_by_lane", digest.context_pressure_by_lane);
      ("intervention_counters", digest.intervention_counters);
      ("local_runtime", digest.local_runtime);
      ("attention_count", `Int (List.length digest.attention_items));
      ("top_attention", option_to_json attention_item_to_yojson top_attention);
      ("recommended_action_count", `Int (List.length digest.recommended_actions));
      ( "top_recommendation",
        option_to_json (recommended_action_to_yojson ~actor) top_recommendation );
      ("provenance", `String "derived");
      ("authoritative", `Bool false);
    ]

let summary_of_attention_items (items : attention_item list) =
  let sorted = List.sort compare_attention items in
  let top_item : attention_item option =
    match sorted with item :: _ -> Some item | [] -> None
  in
  let bad_count =
    List.fold_left
      (fun acc (item : attention_item) ->
        if String.equal item.severity "bad" then acc + 1 else acc)
      0 sorted
  in
  let warn_count =
    List.fold_left
      (fun acc (item : attention_item) ->
        if String.equal item.severity "warn" then acc + 1 else acc)
      0 sorted
  in
  `Assoc
    [
      ("count", `Int (List.length sorted));
      ("bad_count", `Int bad_count);
      ("warn_count", `Int warn_count);
      ("top_item", option_to_json attention_item_to_yojson top_item);
      ("provenance", `String "derived");
      ("authoritative", `Bool false);
    ]

let dedup_recommendations (items : recommended_action list) =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | (item : recommended_action) :: rest ->
        let key =
          String.concat "|"
            [
              item.action_type;
              item.target_type;
              Option.value ~default:"" item.target_id;
              String.trim item.reason |> String.lowercase_ascii;
            ]
        in
        if List.mem key seen then loop seen acc rest
        else loop (key :: seen) (item :: acc) rest
  in
  items |> List.sort compare_recommendation |> loop [] []

let summary_of_recommendations ~actor (items : recommended_action list) =
  let sorted = dedup_recommendations items in
  let top_item : recommended_action option =
    match sorted with item :: _ -> Some item | [] -> None
  in
  `Assoc
    [
      ("count", `Int (List.length sorted));
      ( "top_action",
        option_to_json (recommended_action_to_yojson ~actor) top_item );
      ("provenance", `String "fallback");
      ("authoritative", `Bool false);
    ]

let judgment_surface_for_target_type = function
  | "room" -> "command.warroom"
  | "team_session" -> "command.swarm"
  | _ -> "command.warroom"

let judgment_target_type_of_string = function
  | "room" -> Operator_judgment.Room
  | "team_session" -> Operator_judgment.Team_session
  | _ -> Operator_judgment.Room

let fresh_operator_judgment config ~target_type ~target_id =
  let judgment_target_type = judgment_target_type_of_string target_type in
  let surface = judgment_surface_for_target_type target_type in
  match
    Operator_judgment.latest_active config ~surface
      ~target_type:judgment_target_type ~target_id
  with
  | Some value when Operator_judgment.is_fresh value ->
      Some (Operator_judgment.to_yojson value)
  | _ -> None

let judgment_summary_json judgment_json =
  `Assoc
    [
      ("summary", judgment_json |> U.member "summary");
      ("confidence", judgment_json |> U.member "confidence");
      ("provenance", `String "judgment");
      ("authoritative", `Bool true);
      ("surface", judgment_json |> U.member "surface");
      ("fresh_until", judgment_json |> U.member "fresh_until");
      ("keeper_name", judgment_json |> U.member "keeper_name");
      ("fallback_used", judgment_json |> U.member "fallback_used");
      ("disagreement_with_truth", judgment_json |> U.member "disagreement_with_truth");
    ]

let active_guidance_fields ~config ~actor ~target_type ~target_id
    ~fallback_recommendations ~fallback_summary =
  let fallback_recommendation_json =
    `List
      (List.map (recommended_action_to_yojson ~actor) fallback_recommendations)
  in
  match fresh_operator_judgment config ~target_type ~target_id with
  | Some judgment_json ->
      let judgment_actions =
        match judgment_json |> U.member "recommended_action" with
        | `Assoc _ as value -> `List [ value ]
        | _ -> fallback_recommendation_json
      in
      let recommendation_source =
        match judgment_json |> U.member "recommended_action" with
        | `Assoc _ -> "judgment"
        | _ -> "fallback"
      in
      [
        ("judgment_owner", `String "resident_operator_keeper");
        ("authoritative_judgment_available", `Bool true);
        ("judgment", judgment_json);
        ("active_guidance_layer", `String "judgment");
        ("active_summary", judgment_summary_json judgment_json);
        ("active_recommended_actions", judgment_actions);
        ("active_recommendation_source", `String recommendation_source);
        ("active_recommendation_summary", judgment_summary_json judgment_json);
        ("fallback_recommended_actions", fallback_recommendation_json);
      ]
  | None ->
      [
        ("judgment_owner", `String "fallback_read_model");
        ("authoritative_judgment_available", `Bool false);
        ("judgment", `Null);
        ("active_guidance_layer", `String "fallback");
        ("active_summary", fallback_summary);
        ("active_recommended_actions", fallback_recommendation_json);
        ("active_recommendation_source", `String "fallback");
        ("active_recommendation_summary", fallback_summary);
        ("fallback_recommended_actions", fallback_recommendation_json);
      ]

let event_ts_iso json =
  match U.member "ts_iso" json with `String value -> Some value | _ -> None

let event_type json =
  match U.member "event_type" json with `String value -> Some value | _ -> None

let event_detail_actor json =
  match U.member "detail" json |> U.member "actor" with
  | `String actor ->
      let trimmed = String.trim actor in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let event_detail_kind json =
  match U.member "detail" json |> U.member "kind" with
  | `String kind ->
      let trimmed = String.trim kind in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let event_detail_message json =
  match U.member "detail" json |> U.member "message" with
  | `String message ->
      let trimmed = String.trim message in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let count_spawn_failures events =
  List.fold_left
    (fun acc json ->
      match (event_type json, U.member "detail" json |> U.member "success") with
      | Some "team_step_spawn", `Bool false -> acc + 1
      | _ -> acc)
    0 events

let count_detached_actors events =
  List.fold_left
    (fun acc json ->
      match event_type json with
      | Some "session_agent_detached" -> acc + 1
      | _ -> acc)
    0 events

let empty_note_turn_actors events =
  events
  |> List.filter_map (fun json ->
         match (event_type json, event_detail_kind json, event_detail_actor json) with
         | Some "team_turn", Some "note", Some actor -> (
             match event_detail_message json with None -> Some actor | Some _ -> None)
         | _ -> None)
  |> Team_session_types.dedup_strings

let turn_count_by_actor events actor_name =
  List.fold_left
    (fun acc json ->
      match (event_type json, event_detail_actor json) with
      | Some "team_turn", Some actor when String.equal actor actor_name -> acc + 1
      | _ -> acc)
    0 events

let empty_note_turn_count_for_actor events actor_name =
  List.fold_left
    (fun acc json ->
      match (event_type json, event_detail_kind json, event_detail_actor json) with
      | Some "team_turn", Some "note", Some actor when String.equal actor actor_name -> (
          match event_detail_message json with None -> acc + 1 | Some _ -> acc)
      | _ -> acc)
    0 events

let last_turn_ts_iso_for_actor events actor_name =
  events
  |> List.filter_map (fun json ->
         match (event_type json, event_detail_actor json) with
         | Some "team_turn", Some actor when String.equal actor actor_name ->
             event_ts_iso json
         | _ -> None)
  |> List.rev |> function value :: _ -> Some value | [] -> None

let normalize_digest_target_type value =
  match value with
  | Some raw -> (
      match String.trim raw |> String.lowercase_ascii with
      | "room" -> Ok "room"
      | "team_session" -> Ok "team_session"
      | _ -> Error "target_type must be one of: room, team_session")
  | None -> Ok "room"

let build_worker_cards ~(session : Team_session_types.session) ~(events : Yojson.Safe.t list)
    ~now =
  let worker_keys =
    if session.planned_workers <> [] then
      session.planned_workers
      |> List.map (fun (worker : Team_session_types.planned_worker) ->
             ( worker.runtime_actor,
               Some worker.spawn_agent,
               worker.spawn_role,
               worker.spawn_model,
               Option.map Team_session_types.worker_class_to_string
                 worker.worker_class,
               worker.parent_actor,
               Option.map Team_session_types.capsule_mode_to_string
                 worker.capsule_mode,
               worker.runtime_pool,
               worker.lane_id,
               Option.map Team_session_types.controller_level_to_string
                 worker.controller_level,
               Option.map Team_session_types.control_domain_to_string
                 worker.control_domain,
               worker.supervisor_actor,
               Option.map Team_session_types.model_tier_to_string
                 worker.model_tier,
               Option.map Team_session_types.task_profile_to_string
                 worker.task_profile,
               Option.map Team_session_types.risk_level_to_string
                 worker.risk_level,
               worker.routing_confidence,
               worker.routing_reason ))
    else
      session.agent_names
      |> List.map (fun actor ->
             ( Some actor,
               None,
               None,
               None,
               None,
               None,
               None,
               None,
               None,
               None,
               None,
               None,
               None,
               None,
               None,
               None,
               None ))
  in
  worker_keys
  |> List.map
       (fun
         ( actor,
           spawn_agent,
           spawn_role,
           spawn_model,
           worker_class,
           parent_actor,
           capsule_mode,
           runtime_pool,
           lane_id,
           controller_level,
           control_domain,
           supervisor_actor,
           model_tier,
           task_profile,
           risk_level,
           routing_confidence,
           routing_reason ) ->
         let turn_count =
           match actor with
           | Some value -> turn_count_by_actor events value
           | None -> 0
         in
         let empty_note_turn_count =
           match actor with
           | Some value -> empty_note_turn_count_for_actor events value
           | None -> 0
         in
         let has_turn = turn_count > 0 in
         let last_turn_ts_iso =
           match actor with
           | Some value -> last_turn_ts_iso_for_actor events value
           | None -> None
        in
        let status =
          match actor with
          | Some _ ->
              let age_sec = now -. session.started_at in
              if has_turn then "active"
               else if age_sec >= planned_worker_turn_grace_sec then "planned_no_turn"
               else "grace_period"
           | None -> "planned"
         in
         {
           actor;
           spawn_agent;
           spawn_role;
           spawn_model;
           worker_class;
           parent_actor;
           capsule_mode;
           runtime_pool;
           lane_id;
           controller_level;
           control_domain;
           supervisor_actor;
           model_tier;
           task_profile;
           risk_level;
           routing_confidence;
           routing_reason;
           status;
           turn_count;
           empty_note_turn_count;
           has_turn;
           last_turn_ts_iso;
         })
  |> List.sort compare_worker_card

let session_attention_items ~(session : Team_session_types.session)
    ~(events : Yojson.Safe.t list) ~(worker_cards : worker_card list) ~now =
  let spawn_failure_count = count_spawn_failures events in
  let detached_actor_count = count_detached_actors events in
  let empty_note_actors = empty_note_turn_actors events in
  let low_confidence_cards =
    worker_cards
    |> List.filter (fun (card : worker_card) ->
           match card.routing_confidence with
           | Some value -> value < 0.72
           | None -> false)
  in
  let escalated_worker_count =
    session.planned_workers
    |> List.fold_left
         (fun acc (worker : Team_session_types.planned_worker) ->
           if worker.routing_escalated then acc + 1 else acc)
         0
  in
  let local64_missing_roles =
    if
      session.scale_profile = Team_session_types.Scale_local64
      && session.planned_workers <> []
    then
      let present_roles =
        session.planned_workers
        |> List.filter_map (fun (worker : Team_session_types.planned_worker) ->
               Option.map Team_session_types.worker_class_to_string worker.worker_class)
      in
      [ "manager"; "metacog"; "librarian"; "scout" ]
      |> List.filter (fun role -> not (List.mem role present_roles))
    else []
  in
  let base = [] in
  let base =
    if low_confidence_cards <> [] then
      {
        kind = "low_confidence_routing";
        severity = "warn";
        summary =
          Printf.sprintf "%d worker(s) have low routing confidence"
            (List.length low_confidence_cards);
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence =
          `Assoc
            [
              ( "actors",
                `List
                  (List.filter_map
                     (fun (card : worker_card) ->
                       Option.map (fun actor -> `String actor) card.actor)
                     low_confidence_cards) );
            ];
      }
      :: base
    else base
  in
  let base =
    if escalated_worker_count > 0 then
      {
        kind = "routing_escalation_present";
        severity = "warn";
        summary =
          Printf.sprintf "%d worker(s) were escalated to a higher tier"
            escalated_worker_count;
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence = `Assoc [ ("count", `Int escalated_worker_count) ];
      }
      :: base
    else base
  in
  let base =
    if spawn_failure_count > 0 then
      {
        kind = "spawn_failure_present";
        severity = "bad";
        summary =
          Printf.sprintf "session has %d failed spawn event(s)" spawn_failure_count;
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence = `Assoc [ ("count", `Int spawn_failure_count) ];
      }
      :: base
    else base
  in
  let base =
    if detached_actor_count > 0 then
      {
        kind = "detached_actor_present";
        severity = "warn";
        summary =
          Printf.sprintf "session detached %d runtime actor(s)"
            detached_actor_count;
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence = `Assoc [ ("count", `Int detached_actor_count) ];
      }
      :: base
    else base
  in
  let base =
    if local64_missing_roles <> [] then
      {
        kind = "local64_role_gap";
        severity = "warn";
        summary =
          Printf.sprintf "local64 session is missing swarm support roles: %s"
            (String.concat ", " local64_missing_roles);
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence =
          `Assoc
            [
              ( "missing_roles",
                `List (List.map (fun role -> `String role) local64_missing_roles) );
            ];
      }
      :: base
    else base
  in
  let base =
    if empty_note_actors <> [] then
      {
        kind = "empty_note_turn_present";
        severity = "warn";
        summary = "session contains historical empty note turn evidence";
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence =
          `Assoc
            [
              ("count", `Int (List.length empty_note_actors));
              ("actors", `List (List.map (fun actor -> `String actor) empty_note_actors));
            ];
      }
      :: base
    else base
  in
  let age_since_last_turn =
    now -. Option.value ~default:session.started_at session.last_turn_at
  in
  let base =
    if session.status = Team_session_types.Running
       && session.planned_workers <> []
       && age_since_last_turn >= stalled_session_threshold_sec
    then
      {
        kind = "stalled_session";
        severity = "bad";
        summary =
          Printf.sprintf "session has been idle for %d seconds"
            (int_of_float age_since_last_turn);
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence =
          `Assoc
            [
              ("last_turn_age_sec", `Int (int_of_float age_since_last_turn));
              ( "last_turn_at",
                option_to_json (fun value -> `Float value) session.last_turn_at );
            ];
      }
      :: base
    else base
  in
  let no_turn_workers =
    if session.status = Team_session_types.Running
       && now -. session.started_at >= planned_worker_turn_grace_sec
    then
      worker_cards
      |> List.filter (fun (card : worker_card) ->
             String.equal card.status "planned_no_turn"
             && Option.value ~default:"" card.actor <> "")
    else []
  in
  let base =
    if no_turn_workers <> [] then
      {
        kind = "planned_worker_without_turn";
        severity = "warn";
        summary =
          Printf.sprintf "%d planned worker(s) have not recorded a turn"
            (List.length no_turn_workers);
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence =
          `Assoc
            [
              ( "actors",
                `List
                  (List.filter_map
                     (fun (card : worker_card) ->
                       Option.map (fun actor -> `String actor) card.actor)
                     no_turn_workers) );
            ];
      }
      :: base
    else base
  in
  List.sort compare_attention base

let session_recommendations ~(session : Team_session_types.session)
    ~(attentions : attention_item list) ~(worker_cards : worker_card list) =
  let no_turn_worker_cards =
    worker_cards
    |> List.filter (fun (card : worker_card) ->
           String.equal card.status "planned_no_turn"
           && Option.is_some card.spawn_agent)
  in
  let suggestions =
    attentions
    |> List.filter_map (fun item ->
           match item.kind with
           | "spawn_failure_present" ->
               Some
                 {
                   action_type = "team_task_inject";
                   target_type = "team_session";
                   target_id = Some session.session_id;
                   severity = item.severity;
                   reason = item.summary;
                   suggested_payload =
                     `Assoc
                       [
                         ("title", `String "Recover failed worker coverage");
                         ( "description",
                           `String
                             "Spawn failure evidence is present. Add explicit recovery work or reassign the missing worker contribution." );
                         ("priority", `Int 1);
                       ];
                 }
           | "detached_actor_present" ->
               Some
                 {
                   action_type = "team_note";
                   target_type = "team_session";
                   target_id = Some session.session_id;
                   severity = item.severity;
                   reason = item.summary;
                   suggested_payload =
                     `Assoc
                       [
                         ( "message",
                           `String
                             "[operator] A runtime actor detached. Reassign the missing work and record the replacement explicitly." );
                       ];
                 }
           | "empty_note_turn_present" ->
               Some
                 {
                   action_type = "team_note";
                   target_type = "team_session";
                   target_id = Some session.session_id;
                   severity = item.severity;
                   reason = item.summary;
                   suggested_payload =
                     `Assoc
                       [
                         ( "message",
                           `String
                             "[operator] Record explicit non-empty contribution notes for each worker turn." );
                       ];
                 }
           | "stalled_session" ->
               Some
                 {
                   action_type = "team_stop";
                   target_type = "team_session";
                   target_id = Some session.session_id;
                   severity = item.severity;
                   reason = item.summary;
                   suggested_payload =
                     `Assoc
                       [
                         ("reason", `String "stalled_session_detected");
                         ("generate_report", `Bool true);
                       ];
                 }
           | "planned_worker_without_turn" ->
               if no_turn_worker_cards = [] then
                 Some
                   {
                     action_type = "team_note";
                     target_type = "team_session";
                     target_id = Some session.session_id;
                     severity = item.severity;
                     reason = item.summary;
                     suggested_payload =
                       `Assoc
                         [
                           ( "message",
                             `String
                               "[operator] Planned workers have not reported yet. Record a concrete progress note or detach and replace the missing worker." );
                         ];
                   }
               else
                 Some
                   {
                     action_type = "team_worker_spawn_batch";
                     target_type = "team_session";
                     target_id = Some session.session_id;
                     severity = item.severity;
                     reason = item.summary;
                   suggested_payload =
                       spawn_batch_stub_of_cards no_turn_worker_cards;
                   }
           | "local64_role_gap" ->
	               let missing_roles =
	                 match item.evidence |> U.member "missing_roles" with
	                 | `List xs ->
	                     xs
	                     |> List.filter_map (function
	                          | `String role when String.trim role <> "" ->
	                              Some (String.trim role)
	                          | _ -> None)
	                 | _ -> []
	               in
	               let spawn_batch =
	                 missing_roles
	                 |> List.map (fun role ->
	                        let spawn_role, capsule_mode =
	                          match role with
	                          | "manager" -> ("middle-manager", "capsule")
	                          | "metacog" -> ("metacog-observer", "capsule")
	                          | "librarian" -> ("knowledge-librarian", "capsule")
	                          | "scout" -> ("research-scout", "fresh")
	                          | other -> (other, "fresh")
	                        in
	                        `Assoc
	                          [
	                            ("spawn_agent", `String "llama");
	                            ( "spawn_prompt",
	                              `String
	                                (Printf.sprintf
	                                   "REQUIRED: provide explicit spawn_prompt for local64 %s role"
	                                   role) );
	                            ("spawn_role", `String spawn_role);
	                            ("worker_class", `String role);
	                            ("capsule_mode", `String capsule_mode);
	                            ("runtime_pool", `String "local64");
	                          ])
	               in
	               Some
	                 {
	                   action_type = "team_worker_spawn_batch";
	                   target_type = "team_session";
	                   target_id = Some session.session_id;
	                   severity = item.severity;
	                   reason = item.summary;
	                   suggested_payload = `Assoc [ ("spawn_batch", `List spawn_batch) ];
	                 }
           | "low_confidence_routing" ->
               Some
                 {
                   action_type = "team_note";
                   target_type = "team_session";
                   target_id = Some session.session_id;
                   severity = item.severity;
                   reason = item.summary;
                   suggested_payload =
                     `Assoc
                       [
                         ( "message",
                           `String
                             "[operator] Low-confidence routing detected. Re-check ambiguous workers and escalate disputed outputs to 35B." );
                       ];
                 }
           | "routing_escalation_present" ->
               Some
                 {
                   action_type = "team_note";
                   target_type = "team_session";
                   target_id = Some session.session_id;
                   severity = item.severity;
                   reason = item.summary;
                   suggested_payload =
                     `Assoc
                       [
                         ( "message",
                           `String
                             "[operator] Tier escalation is active. Audit the escalated workers and keep final judgment on 35B." );
                       ];
                 }
	           | _ -> None)
  in
  dedup_recommendations suggestions

let health_from_attention_items (items : attention_item list) =
  if
    List.exists
      (fun (item : attention_item) -> String.equal item.severity "bad")
      items
  then "bad"
  else if items <> [] then "warn"
  else "ok"

let normalize_team_health = function
  | "healthy" -> "ok"
  | "degraded" -> "warn"
  | "critical" -> "bad"
  | other -> other

let build_session_digest config (session : Team_session_types.session) ~now =
  let status_json = Team_session_engine_eio.session_status_json config session in
  let summary = U.member "summary" status_json in
  let team_health = U.member "team_health" status_json in
  let events = Team_session_store.read_events ~max_events:2000 config session.session_id in
  let worker_cards = build_worker_cards ~session ~events ~now in
  let attention_items = session_attention_items ~session ~events ~worker_cards ~now in
  let recommended_actions =
    session_recommendations ~session ~attentions:attention_items ~worker_cards
  in
  let active_agent_count =
    match U.member "active_agents" summary with
    | `List xs -> List.length xs
    | _ -> 0
  in
  let last_turn_age_sec =
    match session.last_turn_at with
    | Some ts -> Some (max 0 (int_of_float (now -. ts)))
    | None when session.status = Team_session_types.Running ->
        Some (max 0 (int_of_float (now -. session.started_at)))
    | None -> None
  in
  {
    session_id = session.session_id;
    goal = session.goal;
    status =
      (match U.member "session" status_json |> U.member "status" with
      | `String status -> status
      | _ -> Team_session_types.status_to_string session.status);
    health =
      (let attention_health = health_from_attention_items attention_items in
       if not (String.equal attention_health "ok") then attention_health
       else
         match U.member "status" team_health with
         | `String status -> normalize_team_health status
         | _ -> attention_health);
    scale_profile =
      (match U.member "scale_profile" summary with
      | `String value -> value
      | _ -> Team_session_types.scale_profile_to_string session.scale_profile);
    control_profile =
      (match U.member "control_profile" summary with
      | `String value -> value
      | _ ->
          Team_session_types.control_profile_to_string session.control_profile);
    planned_worker_count = List.length session.planned_workers;
    active_agent_count;
    last_turn_age_sec;
    worker_class_counts =
      (match U.member "worker_class_counts" summary with
      | `Assoc _ as json -> json
      | _ ->
          Team_session_types.worker_class_counts session.planned_workers
          |> Team_session_types.counts_to_json);
    runtime_pool_counts =
      (match U.member "runtime_pool_counts" summary with
      | `Assoc _ as json -> json
      | _ ->
          Team_session_types.runtime_pool_counts session.planned_workers
          |> Team_session_types.counts_to_json);
    lane_counts =
      (match U.member "lane_counts" summary with
      | `Assoc _ as json -> json
      | _ ->
          Team_session_types.lane_counts session.planned_workers
          |> Team_session_types.counts_to_json);
    controller_counts =
      (match U.member "controller_counts" summary with
      | `Assoc _ as json -> json
      | _ ->
          Team_session_types.controller_level_counts session.planned_workers
          |> Team_session_types.counts_to_json);
    control_domain_counts =
      (match U.member "control_domain_counts" summary with
      | `Assoc _ as json -> json
      | _ ->
          Team_session_types.control_domain_counts session.planned_workers
          |> Team_session_types.counts_to_json);
    tier_counts =
      (match U.member "tier_counts" summary with
      | `Assoc _ as json -> json
      | _ ->
          Team_session_types.model_tier_counts session.planned_workers
          |> Team_session_types.counts_to_json);
    task_profile_counts =
      (match U.member "task_profile_counts" summary with
      | `Assoc _ as json -> json
      | _ ->
          Team_session_types.task_profile_counts session.planned_workers
          |> Team_session_types.counts_to_json);
    escalation_count =
      (match U.member "escalation_count" summary with
      | `Int value -> value
      | `Intlit raw -> (try int_of_string raw with Failure _ -> 0)
      | _ -> Team_session_types.escalation_count session.planned_workers);
    controller_tree =
      (match U.member "controller_tree" summary with
      | `Assoc _ as json -> json
      | _ -> `Assoc []);
    lane_health =
      (match U.member "lane_health" summary with
      | `Assoc _ as json -> json
      | _ -> `Assoc []);
    confidence_heatmap =
      (match U.member "confidence_heatmap" summary with
      | `Assoc _ as json -> json
      | _ -> `Assoc []);
    context_pressure_by_lane =
      (match U.member "context_pressure_by_lane" summary with
      | `Assoc _ as json -> json
      | _ -> `Assoc []);
    intervention_counters =
      (match U.member "intervention_counters" summary with
      | `Assoc _ as json -> json
      | _ -> `Assoc []);
    local_runtime =
      (match U.member "local_runtime" status_json with
      | `Assoc _ as json -> json
      | `Null as json -> json
      | _ -> `Null);
    attention_items;
    recommended_actions;
    worker_cards;
  }

let build_room_attention_items config =
  let command_plane_summary = Command_plane_v2.summary_json config in
  let microarch_signals =
    command_plane_summary
    |> U.member "operations"
    |> U.member "microarch"
    |> U.member "signals"
  in
  let intent_summary =
    command_plane_summary
    |> U.member "intents"
    |> U.member "summary"
  in
  let signal_items =
    [
      ( "command_issue_pressure",
        "command-plane issue pressure is elevated",
        microarch_signals |> U.member "issue_pressure" );
      ( "command_cache_contention",
        "command-plane cache contention is elevated",
        microarch_signals |> U.member "cache_contention" );
      ( "command_scheduler_efficiency",
        "command-plane scheduler efficiency is degraded",
        microarch_signals |> U.member "scheduler_efficiency" );
      ( "command_routing_confidence",
        "command-plane routing confidence is degraded",
        microarch_signals |> U.member "routing_confidence" );
      ( "command_quality_per_token",
        "command-plane quality-per-token is degraded",
        microarch_signals |> U.member "quality_per_token" );
      ( "command_verification_gate_failures",
        "command-plane verification gate failures are accumulating",
        microarch_signals |> U.member "verification_gate_failures" );
      ( "command_rework_rate",
        "command-plane rework rate is elevated",
        microarch_signals |> U.member "rework_rate" );
      ( "command_artifact_scope_drift",
        "command-plane artifact scope drift is elevated",
        microarch_signals |> U.member "artifact_scope_drift" );
      ( "command_speculative_posture",
        "command-plane speculative posture needs review",
        microarch_signals |> U.member "speculative_posture" );
    ]
    |> List.filter_map (fun (kind, summary, signal_json) ->
           match signal_json |> U.member "tone" with
           | `String "warn" ->
               Some
                 {
                   kind;
                   severity = "warn";
                   summary;
                   target_type = "room";
                   target_id = None;
                   actor = None;
                   evidence = signal_json;
                 }
           | `String "bad" ->
               Some
                 {
                   kind;
                   severity = "bad";
                   summary;
                   target_type = "room";
                   target_id = None;
                   actor = None;
                   evidence = signal_json;
                 }
           | _ -> None)
  in
  let intent_items =
    [
      ( "intent_blocked",
        "blocked intents need intervention",
        intent_summary |> U.member "blocked",
        "blocked" );
      ( "intent_handoff_ready",
        "handoff-ready intents need continuity review",
        intent_summary |> U.member "handoff_ready",
        "handoff_ready" );
    ]
    |> List.filter_map (fun (kind, summary, value_json, field_name) ->
           match value_json with
           | `Int count when count > 0 ->
               Some
                 {
                   kind;
                   severity = if count >= 3 then "bad" else "warn";
                   summary;
                   target_type = "room";
                   target_id = None;
                   actor = None;
                   evidence =
                     `Assoc
                       [
                         (field_name, `Int count);
                       ];
                 }
           | _ -> None)
  in
  let pending_confirms = read_pending_confirms config in
  let pending_items =
    if pending_confirms = [] then []
    else
      [
        {
          kind = "pending_confirm_waiting";
          severity = "warn";
          summary =
            Printf.sprintf "%d pending confirmation(s) are waiting for operator input"
              (List.length pending_confirms);
          target_type = "room";
          target_id = None;
          actor = None;
          evidence = `Assoc [ ("count", `Int (List.length pending_confirms)) ];
        };
      ]
  in
  List.sort compare_attention (pending_items @ signal_items @ intent_items)

let room_recommendations config =
  let command_plane_summary = Command_plane_v2.summary_json config in
  let microarch_signals =
    command_plane_summary
    |> U.member "operations"
    |> U.member "microarch"
    |> U.member "signals"
  in
  let intent_summary =
    command_plane_summary
    |> U.member "intents"
    |> U.member "summary"
  in
  let signal_recommendations =
    [
      ( microarch_signals |> U.member "issue_pressure",
        "broadcast",
        "command-plane issue pressure is elevated",
        "[operator] Issue pressure is elevated. Inspect blocked operations, run a dispatch tick, and checkpoint or finalize stale work." );
      ( microarch_signals |> U.member "routing_confidence",
        "broadcast",
        "command-plane routing confidence is degraded",
        "[operator] Routing confidence is low. Inspect candidate scoring and avoid risky manual rebalance until blockers clear." );
      ( microarch_signals |> U.member "quality_per_token",
        "broadcast",
        "command-plane quality-per-token is degraded",
        "[operator] Quality per token is low. Narrow the task graph, reduce weak candidates, and keep coding stages explicit before spawning more workers." );
      ( microarch_signals |> U.member "verification_gate_failures",
        "broadcast",
        "command-plane verification gate failures are accumulating",
        "[operator] Verification failures are stacking up. Stop widening the swarm, inspect implement->verify handoff quality, and patch failing gates first." );
      ( microarch_signals |> U.member "rework_rate",
        "broadcast",
        "command-plane rework rate is elevated",
        "[operator] Rework is high. Deduplicate artifact ownership and collapse parallel work that is touching the same scope." );
      ( microarch_signals |> U.member "artifact_scope_drift",
        "broadcast",
        "command-plane artifact scope drift is elevated",
        "[operator] Artifact scope drift is rising. Require explicit artifact_scope on coding stages before further routing or review." );
      ( microarch_signals |> U.member "cache_contention",
        "broadcast",
        "command-plane cache contention is elevated",
        "[operator] Cache contention is elevated. Reduce concurrent hot lanes or rebalance worker placement before scaling further." );
      ( microarch_signals |> U.member "speculative_posture",
        "broadcast",
        "command-plane speculative posture needs review",
        "[operator] Speculative posture is unstable. Review commit and abort rates before widening speculation." );
      ( intent_summary |> U.member "blocked",
        "broadcast",
        "blocked intents need intervention",
        "[operator] Some intents are blocked. Inspect intent forecast, missing dependencies, and current focus before issuing more work." );
      ( intent_summary |> U.member "handoff_ready",
        "broadcast",
        "handoff-ready intents need continuity review",
        "[operator] Handoff-ready intents are accumulating. Review continuity and either finalize or hand off explicitly." );
    ]
    |> List.filter_map
         (fun (signal_json, action_type, reason, message) ->
           match signal_json with
           | `Assoc _ -> (
               match signal_json |> U.member "tone" with
               | `String ("warn" | "bad" as severity) ->
                   Some
                     {
                       action_type;
                       target_type = "room";
                       target_id = None;
                       severity;
                       reason;
                       suggested_payload = `Assoc [ ("message", `String message) ];
                     }
               | _ -> None)
           | `Int count when count > 0 ->
               Some
                 {
                   action_type;
                   target_type = "room";
                   target_id = None;
                   severity = if count >= 3 then "bad" else "warn";
                   reason;
                   suggested_payload = `Assoc [ ("message", `String message) ];
                 }
           | _ -> None)
  in
  let swarm_resolution_recommendation =
    let swarm = Command_plane_v2.swarm_live_json config () in
    match U.member "resolution_recommendation" swarm with
    | `Assoc _ as recommendation -> (
        match
          recommendation |> U.member "recommended_kind" |> U.to_string_option,
          swarm |> U.member "run_id" |> U.to_string_option
        with
        | Some recommended_kind, Some run_id -> (
            let reason =
              recommendation |> U.member "reason" |> U.to_string_option
              |> Option.value ~default:"swarm-live run needs operator resolution"
            in
            let operation_id =
              match U.member "operation" swarm with
              | `Assoc _ as operation ->
                  operation |> U.member "operation_id" |> U.to_string_option
              | _ -> None
            in
            let payload =
              `Assoc
                [
                  ("run_id", `String run_id);
                  ("reason", `String reason);
                  ( "evidence",
                    match recommendation |> U.member "evidence" with
                    | `Assoc _ as evidence -> evidence
                    | _ -> `Assoc [] );
                ]
            in
            let payload =
              match operation_id with
              | Some value -> (
                  match payload with
                  | `Assoc fields ->
                      `Assoc (("operation_id", `String value) :: fields)
                  | other -> other)
              | None -> payload
            in
            let action_type =
              match recommended_kind with
              | "continue" -> "swarm_run_continue"
              | "rerun" -> "swarm_run_rerun"
              | "abandon" -> "swarm_run_abandon"
              | _ -> ""
            in
            if action_type = "" then None
            else
              Some
                {
                  action_type;
                  target_type = "swarm_run";
                  target_id = Some run_id;
                  severity =
                    (match recommendation |> U.member "recommended_kind" |> U.to_string_option with
                    | Some "continue" -> "warn"
                    | _ -> "bad");
                  reason;
                  suggested_payload = payload;
                })
        | _ -> None)
    | _ -> None
  in
  dedup_recommendations
    (signal_recommendations
    @
    match swarm_resolution_recommendation with
    | Some item -> [ item ]
    | None -> [])

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

let snapshot_json ?actor ?view ?(include_messages = true) ?(include_sessions = true)
    ?(include_keepers = true) (ctx : 'a context) : Yojson.Safe.t =
  let config = ctx.config in
  let initialized = Room.is_initialized config in
  let tracked_sessions =
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
  let summary_fields =
    if initialized && (match view with Summary | Full -> true | _ -> false) then
      let now = Time_compat.now () in
      let session_digests =
        Team_session_store.list_sessions config
        |> List.map (fun session -> build_session_digest config session ~now)
      in
      let room_attention =
        build_room_attention_items config
        @ (session_digests |> List.concat_map (fun digest -> digest.attention_items))
        |> List.sort compare_attention
      in
      let room_recommendation_items =
        room_recommendations config
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
         if initialized && include_keepers then keepers_json config
         else `Assoc [ ("count", `Int 0); ("items", `List []) ] );
       ( "persistent_agents",
         if initialized && include_keepers then persistent_agents_json config
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
       ("pending_confirm_summary", pending_confirm_summary_json ?actor config);
       ("available_actions", available_actions_json);
       ("recent_actions", recent_actions_json config);
     ]
    @ summary_fields)

let digest_json ?actor ?target_type ?target_id ?include_workers (ctx : 'a context) :
    (Yojson.Safe.t, string) result =
  let config = ctx.config in
  if not (Room.is_initialized config) then
    Ok
      (`Assoc
        [
          ("trace_id", `String (trace_id "opsd"));
          ("target_type", `String "room");
          ("target_id", `Null);
          ("health", `String "ok");
          ("judgment_owner", `String "fallback_read_model");
          ("authoritative_judgment_available", `Bool false);
          ("provenance_summary", operator_surface_contract_json);
          ("judgment", `Null);
          ("resident_judge_runtime", resident_judge_runtime_json config);
          ("command_plane", `Assoc []);
          ("swarm_status", Swarm_status.empty_json);
          ("attention_items", `List []);
          ("attention_summary", summary_of_attention_items []);
          ("recommended_actions", `List []);
          ("recommendation_summary", summary_of_recommendations ~actor:"dashboard" []);
          ("active_guidance_layer", `String "fallback");
          ("active_summary", summary_of_recommendations ~actor:"dashboard" []);
          ("active_recommended_actions", `List []);
          ("active_recommendation_source", `String "fallback");
          ("active_recommendation_summary", summary_of_recommendations ~actor:"dashboard" []);
          ("fallback_recommended_actions", `List []);
          ("session_cards", `List []);
          ("worker_cards", `List []);
        ])
  else
    let actor_name = normalized_actor ~context_actor:ctx.agent_name actor in
    let* target_type = normalize_digest_target_type target_type in
    let now = Time_compat.now () in
    let tracked_sessions = Team_session_store.list_sessions config in
    let command_plane_snapshot_json = Command_plane_v2.snapshot_json config in
    let command_plane_digest_json = Command_plane_v2.summary_json config in
    let swarm_status_json =
      Swarm_status.build_json_from_snapshot config command_plane_snapshot_json
    in
    match target_type with
    | "room" ->
        let sessions =
          tracked_sessions
          |> List.map (fun session -> build_session_digest config session ~now)
          |> List.sort compare_session_digest
        in
        let limited_sessions =
          sessions |> List.to_seq |> Seq.take room_digest_session_limit |> List.of_seq
        in
        let attention_items =
          build_room_attention_items config
          @ (limited_sessions |> List.concat_map (fun digest -> digest.attention_items))
          |> List.sort compare_attention
        in
        let recommended_actions =
          dedup_recommendations
            (room_recommendations config
            @ (limited_sessions
              |> List.concat_map (fun digest -> digest.recommended_actions)))
        in
        let fallback_recommendation_summary =
          summary_of_recommendations ~actor:actor_name recommended_actions
        in
        let active_guidance =
          active_guidance_fields ~config ~actor:actor_name ~target_type:"room"
            ~target_id:None ~fallback_recommendations:recommended_actions
            ~fallback_summary:fallback_recommendation_summary
        in
        Ok
          (`Assoc
            ([
              ("trace_id", `String (trace_id "opsd"));
              ("target_type", `String "room");
              ("target_id", `Null);
              ("health", `String (health_from_attention_items attention_items));
              ("provenance_summary", operator_surface_contract_json);
              ("resident_judge_runtime", resident_judge_runtime_json config);
              ("command_plane", command_plane_digest_json);
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
              ("attention_items", `List (List.map attention_item_to_yojson attention_items));
              ("attention_summary", summary_of_attention_items attention_items);
              ( "recommended_actions",
                `List
                  (List.map (recommended_action_to_yojson ~actor:actor_name)
                     recommended_actions) );
              ("recommendation_summary", fallback_recommendation_summary);
              ( "session_cards",
                `List
                  (List.map (session_card_to_yojson ~actor:actor_name) limited_sessions)
              );
              ("worker_cards", `List []);
            ]
            @ active_guidance))
    | "team_session" -> (
        match target_id with
        | None -> Error "target_id is required when target_type=team_session"
        | Some session_id -> (
            match Team_session_store.load_session config session_id with
            | None ->
                Error (Printf.sprintf "team session not found: %s" session_id)
            | Some session ->
                let digest = build_session_digest config session ~now in
                let worker_cards =
                  let should_include =
                    match include_workers with
                    | Some value -> value
                    | None -> true
                  in
                  if should_include then digest.worker_cards else []
                in
                let fallback_recommendation_summary =
                  summary_of_recommendations ~actor:actor_name
                    digest.recommended_actions
                in
                let active_guidance =
                  active_guidance_fields ~config ~actor:actor_name
                    ~target_type:"team_session" ~target_id:(Some session_id)
                    ~fallback_recommendations:digest.recommended_actions
                    ~fallback_summary:fallback_recommendation_summary
                in
                Ok
                  (`Assoc
                    ([
                      ("trace_id", `String (trace_id "opsd"));
                      ("target_type", `String "team_session");
                      ("target_id", `String session_id);
                      ("health", `String digest.health);
                      ("provenance_summary", operator_surface_contract_json);
                      ("resident_judge_runtime", resident_judge_runtime_json config);
                      ("command_plane", command_plane_digest_json);
                      ("swarm_status", swarm_status_json);
                      ( "attention_items",
                        `List
                          (List.map attention_item_to_yojson digest.attention_items)
                      );
                      ("attention_summary", summary_of_attention_items digest.attention_items);
                      ( "recommended_actions",
                        `List
                          (List.map (recommended_action_to_yojson ~actor:actor_name)
                             digest.recommended_actions) );
                      ("recommendation_summary", fallback_recommendation_summary);
                      ("session_cards", `List [ session_card_to_yojson ~actor:actor_name digest ]);
                      ("worker_cards", `List (List.map worker_card_to_yojson worker_cards));
                    ]
                    @ active_guidance))))
    | _ -> Error "unsupported target_type"

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
  | "lodge_poke" -> "lodge_tick"
  | "lodge_tick" -> "lodge_tick"
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
  | "broadcast" | "room_pause" | "room_resume" | "task_inject" | "lodge_tick" -> "room"
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

let action_request_of_args ?actor_hint ctx args =
  let action_type =
    get_string args "action_type" "" |> String.trim |> String.lowercase_ascii
    |> canonical_action_type
  in
  let raw_target_type =
    get_string args "target_type" "" |> String.trim |> String.lowercase_ascii
  in
  let actor =
    normalized_actor ~context_actor:ctx.agent_name
      (match get_string_opt args "actor" with
      | Some actor -> Some actor
      | None -> actor_hint)
  in
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
  | "lodge_tick" -> "lodge_tick"
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

let string_of_trigger = function
  | Lodge_heartbeat.Scheduled -> "scheduled"
  | Lodge_heartbeat.ContentAlert _ -> "content_alert"
  | Lodge_heartbeat.Mentioned _ -> "mentioned"
  | Lodge_heartbeat.ManualTrigger -> "manual"

let checkin_json (name, trigger, result) =
  let outcome_fields =
    match result with
    | Lodge_heartbeat.Acted { summary; _ } ->
        [ ("outcome", `String "acted"); ("summary", `String summary) ]
    | Lodge_heartbeat.Passed reason ->
        [ ("outcome", `String "passed"); ("reason", `String reason) ]
    | Lodge_heartbeat.Skipped reason ->
        [ ("outcome", `String "skipped"); ("reason", `String reason) ]
  in
  `Assoc
    ([
       ("name", `String name);
       ("trigger", `String (string_of_trigger trigger));
     ]
    @ outcome_fields)

let lodge_tick_result_json (result : Lodge_heartbeat.heartbeat_result) =
  let skipped_reason =
    if result.agents_checked = 0 then Some "no agents selected for this tick"
    else None
  in
  let acted =
    result.checkins
    |> List.filter_map (fun (name, _, checkin) ->
           match checkin with
           | Lodge_heartbeat.Acted { summary; _ } ->
               Some (`Assoc [ ("name", `String name); ("summary", `String summary) ])
           | Lodge_heartbeat.Passed _ | Lodge_heartbeat.Skipped _ -> None)
  in
  let skipped =
    result.checkins
    |> List.filter_map (fun (name, _, checkin) ->
           match checkin with
           | Lodge_heartbeat.Skipped reason ->
               Some (`Assoc [ ("name", `String name); ("reason", `String reason) ])
           | Lodge_heartbeat.Acted _ | Lodge_heartbeat.Passed _ -> None)
  in
  let passed =
    result.checkins
    |> List.filter_map (fun (name, _, checkin) ->
           match checkin with
           | Lodge_heartbeat.Passed reason ->
               Some (`Assoc [ ("name", `String name); ("reason", `String reason) ])
           | Lodge_heartbeat.Acted _ | Lodge_heartbeat.Skipped _ -> None)
  in
  `Assoc
    [
      ("hour", `Int result.current_hour);
      ("checked", `Int result.agents_checked);
      ("acted", `Int (List.length acted));
      ("acted_names", `List (List.map (fun row -> row |> U.member "name") acted));
      ("activity_report", `String result.activity_report);
      ("quiet_hours_overridden", `Bool true);
      ( "skipped_reason",
        match skipped_reason with Some reason -> `String reason | None -> `Null );
      ("acted_rows", `List acted);
      ("passed_rows", `List passed);
      ("skipped_rows", `List skipped);
      ("checkins", `List (List.map checkin_json result.checkins));
    ]

let lodge_tick_ack_json ~mode ~status ~manual_tick_running =
  `Assoc
    [
      ("status", `String status);
      ("mode", `String mode);
      ("quiet_hours_overridden", `Bool true);
      ("manual_tick_running", `Bool manual_tick_running);
    ]

let tool_keeper_ctx (ctx : 'a context) : _ Tool_keeper.context =
  { config = ctx.config; sw = ctx.sw; clock = ctx.clock }

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
  | "lodge_tick" ->
      let* () = validate_target_type "room" request in
      if not Env_config.LodgeV2.enabled then
        Ok
          (`Assoc
            [
              ("delegated_tool", `String "lodge_tick");
              ( "result",
                `Assoc
                  [
                    ("checked", `Int 0);
                    ("acted", `Int 0);
                    ("acted_names", `List []);
                    ("quiet_hours_overridden", `Bool true);
                    ("activity_report", `String "Lodge heartbeat is disabled");
                    ("skipped_reason", `String "lodge heartbeat disabled");
                    ("checkins", `List []);
                  ] );
            ])
      else
        let wait_for_result = get_bool request.payload "wait" false in
        if wait_for_result then
          if (Lodge_heartbeat.lodge_status ()).ls_manual_tick_running then
            Ok
              (`Assoc
                [
                  ("delegated_tool", `String "lodge_tick");
                  ( "result",
                    lodge_tick_ack_json ~mode:"sync" ~status:"already_running"
                      ~manual_tick_running:true );
                ])
          else
            let result = Lodge_heartbeat.trigger_heartbeat ctx.config in
            Ok
              (`Assoc
                [
                  ("delegated_tool", `String "lodge_tick");
                  ("result", lodge_tick_result_json result);
                ])
        else
          let status =
            match Lodge_heartbeat.trigger_heartbeat_async ~sw:ctx.sw ctx.config with
            | `Started -> "accepted"
            | `Already_running -> "already_running"
          in
          Ok
            (`Assoc
              [
                ("delegated_tool", `String "lodge_tick");
                ( "result",
                  lodge_tick_ack_json ~mode:"async" ~status
                    ~manual_tick_running:(status = "accepted" || status = "already_running") );
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
      let args =
        `Assoc
          [
            ("name", `String name);
            ("message", `String message);
          ]
      in
      let keeper_ctx : _ Tool_keeper.context =
        { config = ctx.config; sw = ctx.sw; clock = ctx.clock }
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
  | "broadcast" | "room_pause" | "room_resume" | "lodge_tick"
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
  let request = action_request_of_args ?actor_hint ctx args in
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
  let actor =
    normalized_actor ~context_actor:ctx.agent_name
      (match get_string_opt args "actor" with
      | Some actor -> Some actor
      | None -> actor_hint)
  in
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
